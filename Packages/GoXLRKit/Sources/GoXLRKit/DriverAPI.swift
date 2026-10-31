// The XLR driver's user-client interface as Swift values. The layout is
// XLRDriverABI.h, shared with the dext; this file only encodes and decodes it.

import Foundation
import XLRDriverABI

public enum DriverState: UInt32, Sendable { case starting = 0, ready = 1, failed = 2 }

public enum StartFailure: UInt32, Sendable {
    case none = 0, unknownModel, open, configuration, globalData, badMagic, payloadLimit, uninitialised, reset,
         versions, inputState
}

public enum DeviceModel: UInt32, Sendable { case unknown = 0, mini = 1, full = 2 }

/// The dext's refusals: the SPEC.md section 8 verdicts, then its own.
public enum RejectReason: UInt32, Error, Sendable {
    case opcode = 1, index, firmware, length, value, hardwareRisk, writesDisabled, malformed
}

public struct DriverInfo: Equatable, Sendable {
    public var abiVersion: UInt32
    public var driverVersion: UInt32
    public var state: DriverState?
    public var startFailure: StartFailure?
    public var failureReturn: UInt32
    /// What failed, when the failed start step was a command.
    public var startError: DCPError?
    public var model: DeviceModel?
    public var dcpVersion: UInt32
    public var maxPayload: UInt32
    public var firmware: [UInt32]
    public var versions: Versions?
    /// The highest PROMPT.md Phase 5 risk tier the driver allows; 0 = reads only.
    public var writeTier: UInt32
    public var pollIntervalMs: UInt32
    public var commandsSent, commandsRejected, commandsFailed, polls, pollFailures, events: UInt64

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == MemoryLayout<XLRDriverInfo>.size else { return nil }
        let raw = bytes.withUnsafeBytes { $0.loadUnaligned(as: XLRDriverInfo.self) }
        abiVersion = raw.abiVersion
        driverVersion = raw.driverVersion
        state = DriverState(rawValue: raw.state)
        startFailure = StartFailure(rawValue: raw.startFailure)
        failureReturn = raw.failureReturn
        var header = XLRCommandReplyHeader()
        header.detail = raw.startError
        header.dcpStatus = raw.startDcpStatus
        header.ioReturn = raw.failureReturn
        startError = DriverCommand.transportError(header)
        model = DeviceModel(rawValue: raw.model)
        dcpVersion = raw.dcpVersion
        maxPayload = raw.maxPayload
        firmware = [raw.firmware.0, raw.firmware.1, raw.firmware.2, raw.firmware.3]
        let versionBytes = Swift.withUnsafeBytes(of: raw.versions) { Array($0) }
        versions = state == .ready ? Versions(versionBytes) : nil
        writeTier = raw.writeTier
        pollIntervalMs = raw.pollIntervalMs
        commandsSent = raw.commandsSent
        commandsRejected = raw.commandsRejected
        commandsFailed = raw.commandsFailed
        polls = raw.polls
        pollFailures = raw.pollFailures
        events = raw.events
    }
}

public enum CommandOutcome: Equatable, Sendable {
    case ok(payload: [UInt8], attempts: UInt32)
    case rejected(RejectReason)
    case failed(DCPError, attempts: UInt32)
    case notReady
}

public enum DriverCommand {
    /// XLRCommandHeader + payload.
    public static func encode(category: UInt32, index: UInt32, payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendLE(category)
        bytes.appendLE(index)
        bytes.appendLE(UInt32(payload.count))
        return bytes + payload
    }

    /// XLRCommandReplyHeader + payload. Nil when the reply is malformed.
    public static func decode(_ bytes: [UInt8]) -> CommandOutcome? {
        let size = MemoryLayout<XLRCommandReplyHeader>.size
        guard bytes.count >= size else { return nil }
        let header = bytes.withUnsafeBytes { $0.loadUnaligned(as: XLRCommandReplyHeader.self) }
        guard bytes.count == size + Int(header.payloadLength) else { return nil }
        switch header.result {
        case UInt32(XLRCommandResultOK.rawValue):
            return .ok(payload: Array(bytes[size...]), attempts: header.attempts)
        case UInt32(XLRCommandResultRejected.rawValue):
            return RejectReason(rawValue: header.detail).map { .rejected($0) }
        case UInt32(XLRCommandResultFailed.rawValue):
            return transportError(header).map { .failed($0, attempts: header.attempts) }
        case UInt32(XLRCommandResultNotReady.rawValue):
            return .notReady
        default:
            return nil
        }
    }

    static func transportError(_ header: XLRCommandReplyHeader) -> DCPError? {
        switch header.detail {
        case UInt32(XLRTransportErrorTransfer.rawValue): return .transfer(Int32(bitPattern: header.ioReturn))
        case UInt32(XLRTransportErrorStall.rawValue): return .stall
        case UInt32(XLRTransportErrorWaitTimeout.rawValue): return .waitTimeout
        case UInt32(XLRTransportErrorReplyTooShort.rawValue): return .replyTooShort
        case UInt32(XLRTransportErrorOpcodeMismatch.rawValue): return .opcodeMismatch
        case UInt32(XLRTransportErrorSequenceMismatch.rawValue): return .sequenceMismatch
        case UInt32(XLRTransportErrorLengthMismatch.rawValue): return .lengthMismatch
        case UInt32(XLRTransportErrorReplyTooLarge.rawValue): return .replyTooLarge
        case UInt32(XLRTransportErrorDcpStatus.rawValue): return .dcpStatus(DCPStatus(rawValue: header.dcpStatus))
        case UInt32(XLRTransportErrorStopping.rawValue): return .stopping
        default: return nil
        }
    }
}

public enum DriverEvent: Equatable, Sendable {
    case inputState(sequence: UInt64, InputState)
    case driverState(sequence: UInt64, DriverState?, StartFailure?)
    /// The connection to the driver closed (it stopped, or was replaced).
    case disconnected

    /// XLR_EVENT_VALUE_COUNT values from AsyncCompletion. Nil for unknown kinds.
    public init?(values: [UInt64]) {
        guard values.count == Int(XLR_EVENT_VALUE_COUNT) else { return nil }
        switch values[0] {
        case UInt64(XLREventKindInputState.rawValue):
            var bytes = [UInt8]()
            bytes.appendLE(values[2])
            bytes.appendLE(UInt32(truncatingIfNeeded: values[3]))
            guard let state = InputState(bytes) else { return nil }
            self = .inputState(sequence: values[1], state)
        case UInt64(XLREventKindDriverState.rawValue):
            self = .driverState(sequence: values[1], DriverState(rawValue: UInt32(truncatingIfNeeded: values[2])),
                                StartFailure(rawValue: UInt32(truncatingIfNeeded: values[3])))
        default:
            return nil
        }
    }
}

/// What goxlrctl and the helper talk to: the driver, or the simulator.
public protocol XLRDevice: AnyObject {
    func info() throws -> DriverInfo
    func command(category: UInt32, index: UInt32, payload: [UInt8]) throws -> CommandOutcome
    /// Events arrive on `queue` until `close()`.
    func subscribe(queue: DispatchQueue, handler: @escaping (DriverEvent) -> Void) throws
    func close()
}

public extension XLRDevice {
    func versions() throws -> Result<Versions, CommandFailure> {
        try read(category: 0x80F, index: 0).flatMap { Versions($0).map { .success($0) } ?? .failure(.badPayload) }
    }

    /// Device identity: show it, never log or store it (SPEC.md section 7).
    func serial() throws -> Result<String, CommandFailure> {
        try read(category: 0x80F, index: 1).map(SerialReply.serial)
    }

    func inputState() throws -> Result<InputState, CommandFailure> {
        try read(category: 0x800, index: 0).flatMap { InputState($0).map { .success($0) } ?? .failure(.badPayload) }
    }

    private func read(category: UInt32, index: UInt32) throws -> Result<[UInt8], CommandFailure> {
        let outcome = try command(category: category, index: index, payload: [])
        if case .ok(let payload, _) = outcome { return .success(payload) }
        return .failure(outcome.failure ?? .badPayload)
    }
}

public enum CommandFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case rejected(RejectReason)
    case transport(DCPError)
    case notReady
    case badPayload

    public var description: String {
        switch self {
        case .rejected(let reason): return "rejected by the driver (\(reason))"
        case .transport(let error): return "failed (\(error))"
        case .notReady: return "the driver isn't ready"
        case .badPayload: return "unexpected reply payload"
        }
    }
}

public extension CommandOutcome {
    /// Why the command didn't succeed; nil when it did.
    var failure: CommandFailure? {
        switch self {
        case .ok: return nil
        case .rejected(let reason): return .rejected(reason)
        case .failed(let error, _): return .transport(error)
        case .notReady: return .notReady
        }
    }
}
