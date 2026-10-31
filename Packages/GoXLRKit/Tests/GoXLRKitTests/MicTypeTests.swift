// The saved mic settings and what the helper sends for them when the driver attaches.

import XCTest
@testable import GoXLRKit

final class MicTypeTests: XCTestCase {
    // The same bytes goxlrctl sent in the H3.4 session (LEDGER L-126–L-128).
    func testPayloads() {
        XCTAssertEqual(MicSetup.phantomPayload(on: true), [0, 0, 0, 0, 1, 0, 0, 0])
        XCTAssertEqual(MicSetup.phantomPayload(on: false), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(MicSetup.gainPayload(type: .condenser, dB: 40), [2, 0, 0, 0, 0, 0, 0x28, 0])
        XCTAssertEqual(MicSetup.gainPayload(type: .dynamic, dB: 25), [1, 0, 0, 0, 0, 0, 0x19, 0])
        XCTAssertEqual(MicSetup.gatePayload(dB: -59), [0, 2, 3, 0, 0, 0, 0x6c, 0xc2])
    }

    func testAttachNeverTurnsPhantomOn() {
        let off = MicSetup.phantomPayload(on: false)
        XCTAssertEqual(MicSetup.payloadOnAttach(MicSettings(type: .dynamic)), off)
        XCTAssertEqual(MicSetup.payloadOnAttach(MicSettings(type: .jack)), off)
        XCTAssertNil(MicSetup.payloadOnAttach(MicSettings(type: .condenser)))
        XCTAssertNil(MicSetup.payloadOnAttach(MicSettings()))
        for type in MicType.allCases {
            let payload = MicSetup.payloadOnAttach(MicSettings(type: type, gain: 40, gateThreshold: -59)) ?? []
            XCTAssertFalse(stride(from: 0, to: payload.count, by: 8).contains { payload[$0..<$0 + 8] == [0, 0, 0, 0, 1, 0, 0, 0] })
        }
    }

    func testAttachSendsGainAndGate() {
        XCTAssertEqual(MicSetup.payloadOnAttach(MicSettings(type: .condenser, gain: 40, gateThreshold: -59)),
                       MicSetup.gainPayload(type: .condenser, dB: 40) + MicSetup.gatePayload(dB: -59))
        XCTAssertEqual(MicSetup.payloadOnAttach(MicSettings(type: .dynamic, gain: 50)),
                       MicSetup.phantomPayload(on: false) + MicSetup.gainPayload(type: .dynamic, dB: 50))
        // Gain needs a type to pick its key; a gate threshold doesn't.
        XCTAssertEqual(MicSetup.payloadOnAttach(MicSettings(gain: 40, gateThreshold: -40)), MicSetup.gatePayload(dB: -40))
    }

    func testSettingsStayInTheTestedRange() {
        let settings = MicSettings(type: .condenser, gain: 90, gateThreshold: -80)
        XCTAssertEqual(settings.gain, 72)
        XCTAssertEqual(settings.gateThreshold, -59)
        XCTAssertEqual(MicSettings(gain: -5, gateThreshold: 0).gain, 0)
        XCTAssertEqual(MicSettings(gateThreshold: 0).gateThreshold, -20)
    }

    func testSavedValuesRoundTrip() {
        for type in MicType.allCases { XCTAssertEqual(MicType(rawValue: type.rawValue), type) }
        XCTAssertNil(MicType(rawValue: "ribbon"))
    }
}

final class MicLevelTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(MicLevel([0xff, 0x0f])?.dBFS ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(MicLevel([0x58, 0x00])?.dBFS ?? 0, -33.35, accuracy: 0.01)   // gain 40 in a quiet room
        XCTAssertEqual(MicLevel([0, 0])?.dBFS, -90)
        XCTAssertNil(MicLevel([1]))
    }
}
