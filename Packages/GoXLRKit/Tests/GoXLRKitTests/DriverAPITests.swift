// The Swift side of XLRDriverABI.h, and the simulator behind the same interface.

import Foundation
import XCTest
import XLRDriverABI
@testable import GoXLRKit

final class DriverAPITests: XCTestCase {
    func testLayoutsMatchTheHeader() {
        XCTAssertEqual(MemoryLayout<XLRDriverInfo>.size, 136)
        XCTAssertEqual(MemoryLayout<XLRCommandHeader>.size, 12)
        XCTAssertEqual(MemoryLayout<XLRCommandReplyHeader>.size, 24)
        XCTAssertEqual(XLR_USER_CLIENT_TYPE, 0x786c_7264)
    }

    func testCommandEncoding() {
        XCTAssertEqual(DriverCommand.encode(category: 0x80F, index: 1, payload: [0xAA]),
                       [0x0F, 0x08, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0xAA])
    }

    func reply(result: UInt32, detail: UInt32, dcpStatus: UInt32 = 0, ioReturn: UInt32 = 0, attempts: UInt32 = 1,
               payload: [UInt8] = []) -> [UInt8] {
        var bytes = [UInt8]()
        for value in [result, detail, dcpStatus, ioReturn, attempts, UInt32(payload.count)] { bytes.appendLE(value) }
        return bytes + payload
    }

    func testOutcomeFailures() {
        XCTAssertNil(CommandOutcome.ok(payload: [], attempts: 1).failure)
        XCTAssertEqual(CommandOutcome.rejected(.hardwareRisk).failure, .rejected(.hardwareRisk))
        XCTAssertEqual(CommandOutcome.notReady.failure?.description, "the driver isn't ready")
        XCTAssertEqual(CommandFailure.rejected(.hardwareRisk).description, "rejected by the driver (hardwareRisk)")
    }

    func testReplyDecoding() {
        XCTAssertEqual(DriverCommand.decode(reply(result: 0, detail: 0, payload: [1, 2, 3])),
                       .ok(payload: [1, 2, 3], attempts: 1))
        XCTAssertEqual(DriverCommand.decode(reply(result: 1, detail: 6)), .rejected(.hardwareRisk))
        XCTAssertEqual(DriverCommand.decode(reply(result: 1, detail: 7)), .rejected(.writesDisabled))
        XCTAssertEqual(DriverCommand.decode(reply(result: 2, detail: 9, dcpStatus: 8, attempts: 2)),
                       .failed(.dcpStatus(DCPStatus(rawValue: 8)), attempts: 2))
        XCTAssertEqual(DriverCommand.decode(reply(result: 2, detail: 1, ioReturn: 0xE000_5000)),
                       .failed(.transfer(Int32(bitPattern: 0xE000_5000)), attempts: 1))
        XCTAssertEqual(DriverCommand.decode(reply(result: 3, detail: 0)), .notReady)
        // A payload length that disagrees with the bytes, or an unknown result, is malformed.
        XCTAssertNil(DriverCommand.decode(Array(reply(result: 0, detail: 0, payload: [1, 2]).dropLast())))
        XCTAssertNil(DriverCommand.decode(reply(result: 9, detail: 0)))
        XCTAssertNil(DriverCommand.decode(reply(result: 1, detail: 99)))
    }

    func testEventDecoding() {
        let state = InputState(buttons: 1 << 4 | 1 << 22, encoders: [0, -5, 10, 0], faders: [255, 128, 0, 64])
        let bytes = state.bytes
        var low: UInt64 = 0
        for i in 0..<8 { low |= UInt64(bytes[i]) << (8 * UInt64(i)) }
        let high = UInt64(bytes[8]) | UInt64(bytes[9]) << 8 | UInt64(bytes[10]) << 16 | UInt64(bytes[11]) << 24
        XCTAssertEqual(DriverEvent(values: [1, 7, low, high]), .inputState(sequence: 7, state))
        XCTAssertEqual(DriverEvent(values: [2, 8, 2, 7]), .driverState(sequence: 8, .failed, .uninitialised))
        XCTAssertNil(DriverEvent(values: [3, 1, 0, 0]))
        XCTAssertNil(DriverEvent(values: [1, 1, 0]))
    }

    func testSimulatorBehavesLikeATier6Driver() throws {
        let simulator = Simulator()
        let info = try simulator.info()
        XCTAssertEqual(info.state, .ready)
        XCTAssertEqual(info.model, .mini)
        XCTAssertEqual(info.versions?.firmwareText, "1.3.0.0")
        XCTAssertEqual(info.writeTier, 6)
        XCTAssertEqual(try simulator.command(category: 0x808, index: 0, payload: [UInt8](repeating: 0, count: 24)),
                       .ok(payload: [], attempts: 1))
        XCTAssertEqual(try simulator.serial(), .success("SIMULATED0000"))
        XCTAssertEqual(try simulator.command(category: 0x802, index: 0, payload: [UInt8](repeating: 0, count: 1024)), .rejected(.writesDisabled))
        XCTAssertEqual(try simulator.command(category: 0x810, index: 0, payload: []), .rejected(.opcode))

        let queue = DispatchQueue(label: "events")
        let received = expectation(description: "events")
        received.expectedFulfillmentCount = 3
        var events = [DriverEvent]()
        try simulator.subscribe(queue: queue) { event in
            events.append(event)
            received.fulfill()
        }
        let moved = InputState(buttons: 0, encoders: [0, 0, 0, 0], faders: [10, 64, 128, 255])
        simulator.setInputState(moved)
        wait(for: [received], timeout: 2)
        queue.sync {}
        XCTAssertEqual(events.last, .inputState(sequence: 2, moved))
        XCTAssertEqual(try simulator.inputState(), .success(moved))
        simulator.close()
    }

    func testDriverIdentifierComesFromTheEmbeddedDriver() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("XLR-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertNil(DriverClient.embeddedDriverIdentifier(in: app))
        let dext = app.appendingPathComponent("Contents/Library/SystemExtensions/com.example.xlr.driver.dext/Contents")
        try FileManager.default.createDirectory(at: dext, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.xlr.driver",
                                                                          "CFBundlePackageType": "DEXT"],
                                                       format: .xml, options: 0)
        try plist.write(to: dext.appendingPathComponent("Info.plist"))
        XCTAssertEqual(DriverClient.embeddedDriverIdentifier(in: app), "com.example.xlr.driver")
    }
}
