// IOKit connection to the XLR driver's user client (ADR 0003 option (d)).
// Opening it needs no entitlement: the dext carries allow-any-userclient-access.

import Foundation
import IOKit
import XLRDriverABI

public enum DriverClientError: Error, Equatable, CustomStringConvertible {
    case notFound
    case open(kern_return_t)
    case call(kern_return_t)
    case badReply

    public var description: String {
        switch self {
        case .notFound: return "the XLR driver isn't running (no matching IOService)"
        case .open(let kr): return String(format: "IOServiceOpen failed: 0x%08x", UInt32(bitPattern: kr))
        case .call(let kr): return String(format: "driver call failed: 0x%08x", UInt32(bitPattern: kr))
        case .badReply: return "the driver's reply doesn't match XLRDriverABI.h"
        }
    }
}

public final class DriverClient: XLRDevice {
    /// The installed app, where `goxlrctl` looks for the driver.
    public static let helperPath = "/Applications/GoXLR Mini Mac.app"

    /// The driver's bundle ID, which follows the build's bundle prefix
    /// (`XLR_BUNDLE_PREFIX`), so other builders' copies find their own driver:
    /// `XLR_DRIVER_BUNDLE_ID` if set, else the driver embedded in this app, else
    /// the one in the installed app, else this project's own.
    public static let bundleIdentifier: String = {
        if let id = ProcessInfo.processInfo.environment["XLR_DRIVER_BUNDLE_ID"], !id.isEmpty { return id }
        return embeddedDriverIdentifier(in: Bundle.main.bundleURL)
            ?? embeddedDriverIdentifier(in: URL(fileURLWithPath: helperPath))
            ?? "yt.felix.xlr.driver"
    }()

    /// The bundle ID of the first driver extension embedded in an app bundle.
    public static func embeddedDriverIdentifier(in app: URL) -> String? {
        let directory = app.appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "dext" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .lazy.compactMap { Bundle(url: $0)?.bundleIdentifier }.first
    }

    /// Matches the driver's IOService: the dext's bundle ID and its class.
    public static func matching() -> CFMutableDictionary {
        let match = IOServiceMatching("IOUserService") as NSMutableDictionary
        match[kIOPropertyMatchKey] = ["CFBundleIdentifier": bundleIdentifier, "IOUserClass": "XLRDriver"]
        return match
    }

    private var connect: io_connect_t = IO_OBJECT_NULL
    private var port: IONotificationPortRef?
    private var events: EventBox?

    /// Opens the first matching driver.
    public convenience init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, Self.matching())
        guard service != IO_OBJECT_NULL else { throw DriverClientError.notFound }
        defer { IOObjectRelease(service) }
        try self.init(service: service)
    }

    public init(service: io_service_t) throws {
        let kr = IOServiceOpen(service, mach_task_self_, XLR_USER_CLIENT_TYPE, &connect)
        guard kr == KERN_SUCCESS else { throw DriverClientError.open(kr) }
    }

    deinit { close() }

    public func info() throws -> DriverInfo {
        var output = [UInt8](repeating: 0, count: MemoryLayout<XLRDriverInfo>.size)
        var size = output.count
        let kr = IOConnectCallStructMethod(connect, UInt32(XLRSelectorInfo.rawValue), nil, 0, &output, &size)
        guard kr == KERN_SUCCESS else { throw DriverClientError.call(kr) }
        guard let info = DriverInfo(Array(output.prefix(size))) else { throw DriverClientError.badReply }
        return info
    }

    public func command(category: UInt32, index: UInt32, payload: [UInt8]) throws -> CommandOutcome {
        let input = DriverCommand.encode(category: category, index: index, payload: payload)
        var output = [UInt8](repeating: 0, count: MemoryLayout<XLRCommandReplyHeader>.size + Int(XLR_MAX_PAYLOAD))
        var size = output.count
        let kr = IOConnectCallStructMethod(connect, UInt32(XLRSelectorCommand.rawValue), input, input.count, &output,
                                           &size)
        guard kr == KERN_SUCCESS else { throw DriverClientError.call(kr) }
        guard let outcome = DriverCommand.decode(Array(output.prefix(size))) else { throw DriverClientError.badReply }
        return outcome
    }

    /// Whether the driver trusts this process (signed by the driver's team):
    /// only trusted clients may send hardware-risk values such as phantom power.
    public func isTrusted() throws -> Bool {
        var value: UInt64 = 0
        var count: UInt32 = 1
        let kr = IOConnectCallScalarMethod(connect, UInt32(XLRSelectorClientTrust.rawValue), nil, 0, &value, &count)
        guard kr == KERN_SUCCESS else { throw DriverClientError.call(kr) }
        return value != 0
    }

    public func streamOwner() throws -> UInt64 {
        var value: UInt64 = 0
        var count: UInt32 = 1
        let kr = IOConnectCallScalarMethod(connect, UInt32(XLRSelectorStreamStatus.rawValue), nil, 0, &value, &count)
        guard kr == KERN_SUCCESS else { throw DriverClientError.call(kr) }
        return value
    }

    /// Resets the USB device: the driver stops and the device re-attaches, as if
    /// replugged, but without cutting its power. The connection closes.
    public func reenumerate() throws {
        let kr = IOConnectCallScalarMethod(connect, UInt32(XLRSelectorReenumerate.rawValue), nil, 0, nil, nil)
        guard kr == KERN_SUCCESS else { throw DriverClientError.call(kr) }
    }

    public func subscribe(queue: DispatchQueue, handler: @escaping (DriverEvent) -> Void) throws {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { throw DriverClientError.badReply }
        IONotificationPortSetDispatchQueue(port, queue)
        let box = EventBox(handler)
        var reference = [io_user_reference_t](repeating: 0, count: Int(kOSAsyncRef64Count))
        reference[kIOAsyncCalloutFuncIndex] = io_user_reference_t(UInt(bitPattern: unsafeBitCast(eventCallback, to: UnsafeRawPointer.self)))
        reference[kIOAsyncCalloutRefconIndex] = io_user_reference_t(UInt(bitPattern: Unmanaged.passUnretained(box).toOpaque()))
        let kr = IOConnectCallAsyncScalarMethod(connect, UInt32(XLRSelectorSubscribe.rawValue),
                                                IONotificationPortGetMachPort(port), &reference,
                                                UInt32(kIOAsyncCalloutCount), nil, 0, nil, nil)
        guard kr == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            throw DriverClientError.call(kr)
        }
        self.port = port
        events = box
    }

    public func close() {
        if connect != IO_OBJECT_NULL {
            IOServiceClose(connect)
            connect = IO_OBJECT_NULL
        }
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
        events = nil
    }
}

private final class EventBox {
    let handler: (DriverEvent) -> Void
    init(_ handler: @escaping (DriverEvent) -> Void) { self.handler = handler }
}

// With four values IOKit calls the array form of IOAsyncCallback (with exactly
// two it would call IOAsyncCallback2; ADR 0003 finding 16).
private let eventCallback: IOAsyncCallback = { refcon, result, args, count in
    guard let refcon, let args, result == kIOReturnSuccess else { return }
    let box = Unmanaged<EventBox>.fromOpaque(refcon).takeUnretainedValue()
    let values = (0..<Int(count)).map { UInt64(UInt(bitPattern: args[$0])) }
    if let event = DriverEvent(values: values) { box.handler(event) }
}

/// Keeps a connection to the driver while it comes and goes: opens it when the
/// driver's service appears, and reports `.disconnected` when it terminates (for
/// example when the dext is updated or restarts). Events arrive on `queue`.
public final class DriverMonitor {
    public enum Change {
        case connected(DriverClient)
        case event(DriverEvent)
        case failed(DriverClientError)
    }

    private let queue: DispatchQueue
    private let handler: (Change) -> Void
    private var port: IONotificationPortRef?
    private var matched: io_iterator_t = IO_OBJECT_NULL
    private var interest: io_object_t = IO_OBJECT_NULL
    private var client: DriverClient?

    public init(queue: DispatchQueue, handler: @escaping (Change) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    public func start() {
        queue.async { [self] in
            guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
            IONotificationPortSetDispatchQueue(port, queue)
            self.port = port
            let context = Unmanaged.passUnretained(self).toOpaque()
            let kr = IOServiceAddMatchingNotification(port, kIOMatchedNotification, DriverClient.matching(),
                                                      monitorMatched, context, &matched)
            if kr != KERN_SUCCESS { handler(.failed(.call(kr))) }
            serviceMatched(matched)
        }
    }

    public func stop() {
        client?.close()
        client = nil
        if interest != IO_OBJECT_NULL { IOObjectRelease(interest); interest = IO_OBJECT_NULL }
        if matched != IO_OBJECT_NULL { IOObjectRelease(matched); matched = IO_OBJECT_NULL }
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }

    fileprivate func serviceMatched(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard client == nil, let port else { continue }
            do {
                let client = try DriverClient(service: service)
                try client.subscribe(queue: queue) { [weak self] event in self?.handler(.event(event)) }
                self.client = client
                let context = Unmanaged.passUnretained(self).toOpaque()
                if interest != IO_OBJECT_NULL { IOObjectRelease(interest) }
                IOServiceAddInterestNotification(port, service, kIOGeneralInterest, monitorInterest, context, &interest)
                handler(.connected(client))
            } catch let error as DriverClientError {
                handler(.failed(error))
            } catch {}
        }
    }

    fileprivate func serviceTerminated() {
        guard let client else { return }
        client.close()
        self.client = nil
        if interest != IO_OBJECT_NULL { IOObjectRelease(interest); interest = IO_OBJECT_NULL }
        handler(.event(.disconnected))
    }
}

// kIOMessageServiceIsTerminated, a function-like macro Swift doesn't import.
private let messageServiceIsTerminated: UInt32 = 0xE000_0010

private func monitorMatched(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let context else { return }
    Unmanaged<DriverMonitor>.fromOpaque(context).takeUnretainedValue().serviceMatched(iterator)
}

private func monitorInterest(_ context: UnsafeMutableRawPointer?, _ service: io_service_t, _ message: UInt32,
                             _ argument: UnsafeMutableRawPointer?) {
    guard let context, message == messageServiceIsTerminated else { return }
    Unmanaged<DriverMonitor>.fromOpaque(context).takeUnretainedValue().serviceTerminated()
}
