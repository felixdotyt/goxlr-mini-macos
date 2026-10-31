// The gate, compressor and bleep payloads.

import XCTest
@testable import GoXLRKit

final class MicProcessingTests: XCTestCase {
    private func pairs(_ payload: [UInt8]) -> [UInt32: Float] {
        var result = [UInt32: Float]()
        for offset in stride(from: 0, to: payload.count, by: 8) {
            result[payload.le32(at: offset)] = Float(bitPattern: payload.le32(at: offset + 4))
        }
        return result
    }

    func testTables() {
        XCTAssertEqual(MicProcessing.gateTimes.count, 46)
        XCTAssertEqual(MicProcessing.gateTimes.first, 10)
        XCTAssertEqual(MicProcessing.gateTimes.last, 2000)
        XCTAssertEqual(MicProcessing.gateAttenuations.count, 26)
        XCTAssertEqual(MicProcessing.compressorAttacks.count, 20)
        XCTAssertEqual(MicProcessing.compressorReleases.count, 20)
    }

    func testNothingSetSendsNothing() {
        XCTAssertEqual(MicProcessing().payload, [])
    }

    // L-136: the bytes sent in the hardware check.
    func testConfirmedEncodings() {
        var processing = MicProcessing()
        processing.gateAttenuation = -12
        processing.compressorMakeUp = 12
        XCTAssertEqual(pairs(processing.payload), [0x30900: -12, 0x60700: 12])
    }

    func testValuesAreClampedToTheTables() {
        var processing = MicProcessing()
        processing.gateAttenuation = -40          // nearest table value
        processing.gateAttack = 99
        processing.compressorRatio = 99
        processing.compressorThreshold = -99
        processing.compressorMakeUp = 99
        processing.bleepLevel = -10
        let values = pairs(processing.payload)
        XCTAssertEqual(values[0x30900], -32)
        XCTAssertEqual(values[0x30400], 45)
        XCTAssertEqual(values[0x60300], 64)
        XCTAssertEqual(values[0x60200], -40)
        XCTAssertEqual(values[0x60700], 24)
        XCTAssertEqual(values[0x70100], -10 * 65536)
    }

    func testDecodingClampsIntoTheTables() throws {
        let json = #"{"compressorRatio":20,"gateAttack":-1,"gateAttenuation":-40,"bleepLevel":5}"#
        let processing = try JSONDecoder().decode(MicProcessing.self, from: Data(json.utf8))
        XCTAssertEqual(processing.compressorRatio, MicProcessing.compressorRatios.count - 1)
        XCTAssertEqual(processing.gateAttack, 0)
        XCTAssertEqual(processing.gateAttenuation, -32)
        XCTAssertEqual(processing.bleepLevel, 0)
    }
}
