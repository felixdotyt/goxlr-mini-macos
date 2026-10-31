// Official profile facts → our profile. Hand-written XML with made-up values.

import XCTest
@testable import GoXLRKit

final class ProfileImportTests: XCTestCase {
    private let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ValueTreeRoot version="1" device="36832">
      <mixerTree micLevel="200" musicLevel="17" chatLevel="999" micToStream="8192" micToChat="0" micToHP="0"
                 micToSampler="0" micToLineOut="0" musicToStream="8192" musicToChat="0" musicToHP="8192"
                 musicToSampler="0" musicToLineOut="0"/>
      <FaderMeter0 FaderMeter0listIndex="0" FaderMeter0Display="METER"/>
      <FaderMeter1 FaderMeter1listIndex="2" FaderMeter1Display="GRADIENT"/>
      <FaderMeter2 FaderMeter2listIndex="8" FaderMeter2Display="SPARKLE"/>
      <mute1 mute1Function="Mute to Stream" mute1offStyle="COLOUR2"/>
      <mute2 mute2Function="All" mute2offStyle="COLOUR2"/>
      <mute3 mute3Function="Mystery" mute3offStyle="DIMMED"/>
    </ValueTreeRoot>
    """

    func testMapping() throws {
        let profile = try OfficialProfile(xml: Data(xml.utf8)).deviceProfile(named: "Imported")
        XCTAssertEqual(profile.name, "Imported")
        XCTAssertEqual(profile.mixer?.volumes, [.mic: 200, .music: 17])          // 999 is out of range: skipped
        XCTAssertEqual(profile.mixer?.routing[.mic], [.broadcast])
        XCTAssertEqual(profile.mixer?.routing[.music], [.broadcast, .headphones])
        XCTAssertNil(profile.mixer?.routing[.chat])
        XCTAssertEqual(profile.mixer?.faders, [.a: .mic, .b: .music])            // listIndex 8 (Headphones) isn't a fader channel
        XCTAssertEqual(profile.mixer?.faderDisplays[.a], FaderDisplay(gradient: false, meter: true))
        XCTAssertEqual(profile.mixer?.faderDisplays[.b], FaderDisplay(gradient: true, meter: false))
        XCTAssertNil(profile.mixer?.faderDisplays[.c])
        XCTAssertEqual(profile.mixer?.muteFunctions, [.a: .toStream, .b: .all]) // "Mystery" stays unset
        XCTAssertEqual(profile.mixer?.offLight, .colour2)
        XCTAssertEqual(profile.mic, MicSettings())
    }

    func testEmptyProfileSetsNothing() throws {
        let profile = try OfficialProfile(xml: Data(#"<ValueTreeRoot version="1"/>"#.utf8)).deviceProfile(named: "Empty")
        XCTAssertEqual(profile.mixer, MixerState())
    }
}

/// Opt-in, like OfficialProfileTests: XLR_SAMPLE_PROFILES names a directory of
/// official profiles (vendor files, never in the repo).
final class SampleProfileImportTests: XCTestCase {
    func testSamplesMapToMixerSettings() throws {
        guard let path = ProcessInfo.processInfo.environment["XLR_SAMPLE_PROFILES"] else { throw XCTSkip("XLR_SAMPLE_PROFILES not set") }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
        var mapped = 0
        for url in urls where url.pathExtension == "goxlr" {
            guard let official = try? OfficialProfile.load(contentsOf: url) else { continue }
            let profile = official.deviceProfile(named: url.deletingPathExtension().lastPathComponent)
            XCTAssertFalse(profile.mixer?.volumes.isEmpty ?? true, url.lastPathComponent)
            XCTAssertEqual(profile.mixer?.faders.count, 4, url.lastPathComponent)
            XCTAssertEqual(profile.mixer?.routing.count, RoutingInput.allCases.count, url.lastPathComponent)
            XCTAssertNotNil(profile.lighting, url.lastPathComponent)
            mapped += 1
        }
        XCTAssertEqual(mapped, 4)
    }
}
