// The colour map layout and the animation payload.

import XCTest
@testable import GoXLRKit

final class LightingTests: XCTestCase {
    func testLayoutMatchesTheCameraChecks() throws {
        // L-122: fader A's strip is slots 20-21; mutes 12-19, logo 10, Bleep 126, Cough 128.
        var lighting = Lighting.uniform(RGB(red: 0, green: 255, blue: 255))
        lighting.colours[.fader1] = [RGB(red: 255, green: 0, blue: 0), RGB(red: 0, green: 255, blue: 0)]
        let map = try XCTUnwrap(lighting.colourMap(features: .testedMini))
        XCTAssertEqual(map.count, 520)
        XCTAssertEqual(Array(map[80..<88]), [0, 0, 255, 0, 0, 255, 0, 0])      // red, green as B G R 0
        XCTAssertEqual(Array(map[48..<52]), [255, 255, 0, 0])                   // mute A on: cyan
        XCTAssertEqual(Array(map[504..<508]), [255, 255, 0, 0])                 // Bleep
        XCTAssertEqual(Array(map[512..<516]), [255, 255, 0, 0])                 // Cough
        XCTAssertEqual(Array(map[40..<44]), [255, 255, 0, 0])                   // logo
        XCTAssertEqual(Array(map[136..<140]), [255, 255, 0, 0])                 // fader B strip at slot 34
        XCTAssertEqual(Array(map[300..<304]), [0, 0, 0, 0])                     // a full-GoXLR slot stays 0
        XCTAssertEqual(Array(map[32..<40]), Array(map[40..<48]))                // slots 8-9 repeat the logo
    }

    func testOlderFirmwareLayout() throws {
        let lighting = Lighting.uniform(RGB(red: 1, green: 2, blue: 3))
        let map = try XCTUnwrap(lighting.colourMap(features: FirmwareFeatures(animations: false, submixes: false, mix2: false)))
        XCTAssertEqual(map.count, 328)
        XCTAssertEqual(Array(map[88..<92]), [3, 2, 1, 0])                       // fader B strip at slot 22
        XCTAssertEqual(Array(map[312..<316]), [3, 2, 1, 0])                     // Bleep at slot 78
    }

    func testIncompleteLightingSendsNothing() {
        var lighting = Lighting.uniform(RGB(red: 1, green: 2, blue: 3))
        lighting.colours[.logo] = nil
        XCTAssertNil(lighting.colourMap(features: .testedMini))
    }

    func testAnimationPayload() {
        XCTAssertEqual(Animation(mode: .retroRainbow, modifier1: 50, modifier2: 200, waterfall: .up).payload, [1, 0, 50, 100, 1])
        XCTAssertEqual(Animation().payload, [0, 5, 0, 0, 2])
        XCTAssertFalse(AnimationMode.available(on: .mini).contains(.ripple))
        XCTAssertEqual(DeviceCommand.animation(Animation().payload).category, 0x816)
    }
}
