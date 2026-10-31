// The official-profile importer against synthetic archives: real element and
// attribute names (docs/protocol/profile-format.md), made-up values. Set
// XLR_SAMPLE_PROFILES to a folder of `.goxlr` files to also check real ones.

import Foundation
import XCTest
@testable import GoXLRKit

final class OfficialProfileTests: XCTestCase {
    // MARK: Builders

    struct Entry {
        var name: String
        var bytes: [UInt8]
        var method: UInt16 = 0
    }

    /// A stored ZIP archive laid out as the official app writes one.
    static func archive(_ entries: [Entry]) -> Data {
        var out = [UInt8](), directory = [UInt8]()
        for entry in entries {
            let name = Array(entry.name.utf8), crc = StoredZip.crc32(entry.bytes), size = UInt32(entry.bytes.count)
            let offset = UInt32(out.count)
            out.appendLE(StoredZip.localSignature)
            for value: UInt16 in [10, 0x800, entry.method, 0, 0] { out.appendLE(value) }
            out.appendLE(crc); out.appendLE(size); out.appendLE(size)
            out.appendLE(UInt16(name.count)); out.appendLE(UInt16(0))
            out += name + entry.bytes

            directory.appendLE(StoredZip.directorySignature)
            for value: UInt16 in [0x14, 10, 0x800, entry.method, 0, 0] { directory.appendLE(value) }
            directory.appendLE(crc); directory.appendLE(size); directory.appendLE(size)
            for value: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { directory.appendLE(value) }
            directory.appendLE(UInt32(0)); directory.appendLE(offset)
            directory += name
        }
        let directoryOffset = UInt32(out.count)
        out += directory
        out.appendLE(StoredZip.endSignature)
        for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { out.appendLE(value) }
        out.appendLE(UInt32(directory.count)); out.appendLE(directoryOffset); out.appendLE(UInt16(0))
        return Data(out)
    }

    /// A made-up scribble entry with bytes above 0x7F and LFs, like a PNG.
    static let scribble = Entry(name: "scribble1.png", bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xC3, 0x28, 0xFE, 0x0A, 0x00, 0x9F])

    static func profileArchive(_ xml: String, extra: [Entry] = [scribble]) -> Data {
        archive([Entry(name: "profile.xml", bytes: Array(xml.utf8))] + extra)
    }

    /// JUCE writes CR LF line ends and a blank line after the declaration.
    static func document(_ elements: [String], root: String = "ValueTreeRoot", rootAttributes: String = "") -> String {
        (["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "", "<\(root)\(rootAttributes)>"]
            + elements.map { "  " + $0 } + ["</\(root)>", ""]).joined(separator: "\r\n")
    }

    static let inputs: [(String, RoutingInput)] = [("mic", .mic), ("lineIn", .lineIn), ("system", .system), ("game", .game),
                                                   ("chat", .chat), ("music", .music), ("sample", .sample), ("console", .console)]
    static let outputs: [(String, RoutingOutput)] = [("Stream", .broadcast), ("Chat", .chatMic), ("HP", .headphones),
                                                     ("Sampler", .sampler), ("LineOut", .lineOut)]

    /// Made-up routing: mic and game go everywhere, music to headphones only, nothing else routed.
    static func routed(_ input: RoutingInput, _ output: RoutingOutput) -> Bool {
        input == .mic || input == .game || (input == .music && output == .headphones)
    }

    static var completeProfile: String {
        let routing = inputs.flatMap { input in
            outputs.map { "\(input.0)To\($0.0)=\"\(routed(input.1, $0.1) ? 8192 : 0)\"" }
        }.joined(separator: " ")
        let levels = "micLevel=\"201\" lineInLevel=\"17\" consoleLevel=\"33\" systemLevel=\"64\" gameLevel=\"99\" chatLevel=\"0\" "
            + "sampleLevel=\"250\" musicLevel=\"140\" headphoneLevel=\"222\" mic2headphoneSubLevel=\"77\" lineOutLevel=\"255\""
        return document([
            // A nested element with a top-level name must not count.
            "<sampleTopLeft sampleTopLeftstate=\"\"><mute1 mute1Function=\"Mute to Phones\"/></sampleTopLeft>",
            "<FaderMeter0 FaderMeter0selected=\"0\" colorGroup=\"faderGroup\" FaderMeter0listIndex=\"3\" FaderMeter0colour0=\"00000000\" "
                + "FaderMeter0colour1=\"FF123456\" FaderMeter0offStyle=\"DIMMED\" FaderMeter0Display=\"METER\"/>",
            "<mute1 mute1selected=\"0\" mute1state=\"1\" mute1offStyle=\"COLOUR2\" mute1colour0=\"ff0a0b0c\" colorGroup=\"muteGroup\" "
                + "mute1Function=\"Mute to Stream\" mute1velocity=\"127\" mute1colour1=\"80FFEEDD\" mute1blink=\"1\" mute1prevLevel=\"180\"/>",
            "<FaderMeter1 FaderMeter1listIndex=\"7\" FaderMeter1colour0=\"FFABCDEF\" FaderMeter1colour1=\"FF000001\" "
                + "FaderMeter1offStyle=\"DIMMEDCOLOUR2\" FaderMeter1Display=\"GRADIENT_METER\"/>",
            "<mute2 mute2state=\"0\" mute2offStyle=\"DIMMED\" mute2colour0=\"FF111111\" mute2Function=\"All\" mute2colour1=\"FF222222\" "
                + "mute2blink=\"0\" mute2prevLevel=\"0\"/>",
            "<FaderMeter2 FaderMeter2listIndex=\"5\" FaderMeter2Display=\"TWO COLOR\"/>",
            "<mute3 mute3Function=\"Mute to Voice Chat\"/>",
            "<FaderMeter3 FaderMeter3listIndex=\"9\" FaderMeter3Display=\"GRADIENT\"/>",
            "<mute4 mute4Function=\"Mute to Line Out\"/>",
            "<reverbEncoder reverbEncoderstate=\"1\" active_set=\"2\"><reverbEncoderpreset1 REVERB_DECAY=\"5\"/></reverbEncoder>",
            "<swear swearselected=\"0\" swearstate=\"0\" swearoffStyle=\"DIMMEDCOLOUR2\" swearcolour0=\"FF00AA00\" swearvelocity=\"127\" swearcolour1=\"FF0000AA\"/>",
            "<muteChat coughButtonToggleSetting=\"1\" coughButtonMuteSourceSelection=\"2\" blink=\"1\" muteChatstate=\"1\" "
                + "muteChatoffStyle=\"DIMMED\" muteChatcolour0=\"FFAA0000\" muteChatcolour1=\"00000000\" coughButtonIsOn=\"1\"/>",
            "<logoX logoXstate=\"0\" logoXoffStyle=\"COLOUR2\" logoXcolour0=\"FF445566\" logoXcolour1=\"ffffffff\"/>",
            "<mixerTree \(levels) \(routing) MiniLockFadersToLabels=\"1\" mixerTreeoffStyle=\"DIMMED\"/>",
            "<globalColour globalColourcolour1=\"00000000\" globalColourcolour0=\"FF7F7F7F\" globalColouroffStyle=\"DIMMED\"/>",
        ], rootAttributes: " version=\"1\" loudness=\"42\" device=\"36836\"")
    }

    func assertThrows(_ data: Data, _ expected: OfficialProfileError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try OfficialProfile(zipData: data), file: file, line: line) {
            XCTAssertEqual($0 as? OfficialProfileError, expected, file: file, line: line)
        }
    }

    func assertDamaged(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try OfficialProfile(zipData: data), file: file, line: line) {
            guard case .damaged = $0 as? OfficialProfileError else {
                return XCTFail("expected a damaged-archive error, got \($0)", file: file, line: line)
            }
        }
    }

    // MARK: Container

    func testCRC32CheckValue() {
        XCTAssertEqual(StoredZip.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoredZip.crc32([UInt8]()), 0)
    }

    func testStoredZipReturnsEntriesByName() throws {
        let zip = try StoredZip(data: Self.archive([Entry(name: "a.txt", bytes: Array("hello".utf8)), Self.scribble]))
        XCTAssertEqual(zip.names, ["a.txt", "scribble1.png"])
        XCTAssertEqual(zip.data(named: "a.txt"), Data("hello".utf8))
        XCTAssertEqual(zip.data(named: "scribble1.png"), Data(Self.scribble.bytes))
        XCTAssertNil(zip.data(named: "A.TXT"))
    }

    func testCompressedEntryRejected() {
        let data = Self.archive([Entry(name: "profile.xml", bytes: Array(Self.document([]).utf8), method: 8)])
        assertThrows(data, .damaged(.compressed(name: "profile.xml", method: 8)))
    }

    func testCRCMismatchRejected() {
        var bytes = [UInt8](Self.profileArchive(Self.completeProfile))
        bytes[30 + "profile.xml".utf8.count + 1] ^= 0x20 // inside the first entry's data
        XCTAssertThrowsError(try OfficialProfile(zipData: Data(bytes))) {
            guard case .damaged(.crcMismatch(name: "profile.xml", _, _)) = $0 as? OfficialProfileError else {
                return XCTFail("expected a CRC mismatch, got \($0)")
            }
        }
    }

    func testTruncatedArchiveRejected() {
        let data = Self.profileArchive(Self.completeProfile)
        assertThrows(data.dropLast(), .damaged(.noEndRecord))
        assertThrows(Data(), .damaged(.noEndRecord))
        // Every shorter prefix fails cleanly, as does a directory that points past the data.
        for length in stride(from: 0, to: data.count, by: 7) { assertDamaged(data.prefix(length)) }
        var bytes = [UInt8](data)
        bytes.replaceSubrange(bytes.count - 6..<bytes.count - 2, with: [0xFF, 0xFF, 0x00, 0x00])
        assertDamaged(Data(bytes))
    }

    /// The installed Default.goxlr's damage: every LF became CR LF and bytes that
    /// aren't valid UTF-8 became U+FFFD.
    func testTextModeDamageRejected() {
        let clean = [UInt8](Self.profileArchive(Self.completeProfile))
        var damaged = [UInt8]()
        for byte in clean {
            switch byte {
            case 0x0A: damaged += [0x0D, 0x0A]
            case 0x80...: damaged += [0xEF, 0xBF, 0xBD]
            default: damaged.append(byte)
            }
        }
        XCTAssertNotEqual(damaged.count, clean.count)
        assertDamaged(Data(damaged))
    }

    func testMissingProfileXMLRejected() {
        assertThrows(Self.archive([Self.scribble]), .missingProfileXML)
        assertThrows(Self.archive([]), .missingProfileXML)
    }

    // MARK: profile.xml

    func testCompleteProfile() throws {
        let profile = try OfficialProfile(zipData: Self.profileArchive(Self.completeProfile))
        XCTAssertEqual(profile.version, 1)
        XCTAssertEqual(profile.devicePID, 0x8FE4)
        XCTAssertEqual(profile.levels, [.mic: 201, .lineIn: 17, .console: 33, .system: 64, .game: 99, .chat: 0, .sample: 250,
                                        .music: 140, .headphones: 222, .micMonitor: 77, .lineOut: 255])
        for (_, input) in Self.inputs {
            let expected = Set(Self.outputs.map(\.1).filter { Self.routed(input, $0) })
            XCTAssertEqual(profile.routing[input], expected, "\(input)")
            XCTAssertEqual(profile.routingValues[input]?.count, 5)
        }
        XCTAssertEqual(profile.routingValues[.music]?[.headphones], 8192)
        XCTAssertEqual(profile.routingValues[.music]?[.broadcast], 0)
        XCTAssertEqual(profile.miniLockFadersToLabels, 1)

        XCTAssertEqual(profile.faders.mapValues(\.channel), [.a: .game, .b: .sample, .c: .lineIn, .d: .lineOut])
        XCTAssertEqual(profile.faders.mapValues(\.knownDisplay), [.a: .meter, .b: .gradientMeter, .c: .twoColour, .d: .gradient])
        let a = try XCTUnwrap(profile.faders[.a])
        XCTAssertEqual(a.colour1?.rgb, RGB(red: 0x12, green: 0x34, blue: 0x56))
        XCTAssertEqual(a.colour1?.alpha, 0xFF)
        XCTAssertEqual(a.colour0?.raw, "00000000")
        XCTAssertEqual(a.colour0?.alpha, 0)
        XCTAssertEqual(a.knownOffStyle, .dimmed)
        XCTAssertEqual(profile.faders[.b]?.knownOffStyle, .dimmedColour2)
        XCTAssertNil(profile.faders[.c]?.colour0)

        XCTAssertEqual(profile.muteButtons.mapValues(\.muteFunction), [.a: .toStream, .b: .all, .c: .toChat, .d: .toLineOut])
        let mute = try XCTUnwrap(profile.muteButtons[.a])
        XCTAssertEqual(mute.button, ProfileButton(state: 1, colour0: ProfileColour(raw: "ff0a0b0c"),
                                                  colour1: ProfileColour(raw: "80FFEEDD"), offStyle: "COLOUR2"))
        XCTAssertEqual(mute.button.colour0?.rgb, RGB(red: 0x0A, green: 0x0B, blue: 0x0C))
        XCTAssertEqual(mute.button.colour1?.alpha, 0x80)
        XCTAssertEqual(mute.button.knownOffStyle, .colour2)
        XCTAssertEqual(mute.blink, 1)
        XCTAssertEqual(mute.prevLevel, 180)

        let cough = try XCTUnwrap(profile.cough)
        XCTAssertEqual(cough.button.state, 1)
        XCTAssertEqual(cough.button.colour0?.rgb, RGB(red: 0xAA, green: 0, blue: 0))
        XCTAssertEqual([cough.toggleSetting, cough.muteSourceSelection, cough.isOn, cough.blink], [1, 2, 1, 1])
        XCTAssertEqual(profile.bleep?.knownOffStyle, .dimmedColour2)
        XCTAssertEqual(profile.bleep?.colour1?.rgb, RGB(red: 0, green: 0, blue: 0xAA))
        XCTAssertEqual(profile.logo?.colour1?.rgb, RGB(red: 0xFF, green: 0xFF, blue: 0xFF))
        XCTAssertEqual(profile.globalColour?.colour0?.rgb, RGB(red: 0x7F, green: 0x7F, blue: 0x7F))
        XCTAssertNil(profile.globalColour?.state)
        XCTAssertEqual(profile.undecoded, [])
    }

    func testMissingOptionalElements() throws {
        // Only some levels and switches, one fader and one mute, nothing else.
        let xml = Self.document([
            "<mixerTree micLevel=\"10\" micToStream=\"8192\" micToHP=\"0\" gameLevel=\"12.5\"/>",
            "<FaderMeter2 FaderMeter2listIndex=\"-1\"/>",
            "<mute4/>",
        ])
        let profile = try OfficialProfile(zipData: Self.profileArchive(xml, extra: []))
        XCTAssertNil(profile.version)
        XCTAssertNil(profile.devicePID)
        XCTAssertEqual(profile.levels, [.mic: 10])
        XCTAssertEqual(profile.routing, [:], "an input with missing switches has no routing set")
        XCTAssertEqual(profile.routingValues, [.mic: [.broadcast: 8192, .headphones: 0]])
        XCTAssertNil(profile.miniLockFadersToLabels)
        XCTAssertEqual(Array(profile.faders.keys), [.c])
        XCTAssertEqual(profile.faders[.c]?.listIndex, -1)
        XCTAssertNil(profile.faders[.c]?.channel)
        XCTAssertNil(profile.faders[.c]?.display)
        XCTAssertEqual(profile.muteButtons, [.d: MuteButton(button: ProfileButton())])
        XCTAssertNil(profile.cough)
        XCTAssertNil(profile.bleep)
        XCTAssertNil(profile.logo)
        XCTAssertNil(profile.globalColour)
        XCTAssertEqual(profile.undecoded, [UndecodedValue(element: "mixerTree", attribute: "gameLevel", value: "12.5")])

        let empty = try OfficialProfile(zipData: Self.profileArchive(Self.document([])))
        XCTAssertEqual(empty.levels, [:])
        XCTAssertEqual(empty.faders, [:])
    }

    func testUnknownValuesStayRaw() throws {
        let xml = Self.document([
            "<mute1 mute1Function=\"Mute to Somewhere\" mute1offStyle=\"SPARKLE\" mute1colour0=\"#FF0000\" mute1colour1=\"FF00FF0\"/>",
            "<mute2 mute2Function=\"all\"/>",
            "<FaderMeter0 FaderMeter0listIndex=\"10\" FaderMeter0Display=\"VU\" FaderMeter0colour0=\"FFGG0000\"/>",
            "<mixerTree micToStream=\"4096\" micToChat=\"0\" micToHP=\"0\" micToSampler=\"0\" micToLineOut=\"0\"/>",
        ])
        let profile = try OfficialProfile(zipData: Self.profileArchive(xml))
        let mute = try XCTUnwrap(profile.muteButtons[.a])
        XCTAssertEqual(mute.function, "Mute to Somewhere")
        XCTAssertNil(mute.muteFunction)
        XCTAssertNil(profile.muteButtons[.b]?.muteFunction, "matching is exact, as stored")
        XCTAssertEqual(mute.button.offStyle, "SPARKLE")
        XCTAssertNil(mute.button.knownOffStyle)
        XCTAssertEqual(mute.button.colour0?.raw, "#FF0000")
        XCTAssertNil(mute.button.colour0?.rgb)
        XCTAssertNil(mute.button.colour1?.argb)
        let fader = try XCTUnwrap(profile.faders[.a])
        XCTAssertEqual(fader.listIndex, 10)
        XCTAssertNil(fader.channel)
        XCTAssertEqual(fader.display, "VU")
        XCTAssertNil(fader.knownDisplay)
        XCTAssertNil(fader.colour0?.rgb)
        XCTAssertNil(profile.routing[.mic], "4096 is neither on nor off")
        XCTAssertEqual(profile.routingValues[.mic]?[.broadcast], 4096)
        XCTAssertEqual(profile.undecoded, [])
    }

    func testNotValueTreeRootRejected() {
        assertThrows(Self.profileArchive(Self.document(["<mixerTree micLevel=\"1\"/>"], root: "PLUGINSETTINGS")),
                     .notValueTreeRoot(found: "PLUGINSETTINGS"))
    }

    func testMalformedXMLReportsPosition() throws {
        let xml = Self.document(["<mixerTree micLevel=\"1\">", "<mute1>"])
        XCTAssertThrowsError(try OfficialProfile(zipData: Self.profileArchive(xml))) {
            guard case let .xmlParse(line, _, message)? = $0 as? OfficialProfileError else {
                return XCTFail("expected an XML error, got \($0)")
            }
            XCTAssertGreaterThanOrEqual(line, 5)
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertThrowsError(try OfficialProfile(zipData: Self.profileArchive(""))) {
            guard case .xmlParse? = $0 as? OfficialProfileError else { return XCTFail("expected an XML error, got \($0)") }
        }
    }

    func testEntityDeclarationsRefused() {
        let xml = "<?xml version=\"1.0\"?>\r\n<!DOCTYPE ValueTreeRoot [<!ENTITY a \"aaaaaaaa\">]>\r\n"
            + "<ValueTreeRoot version=\"&a;\"/>\r\n"
        XCTAssertThrowsError(try OfficialProfile(zipData: Self.profileArchive(xml))) {
            guard case let .xmlParse(_, _, message)? = $0 as? OfficialProfileError else {
                return XCTFail("expected an XML error, got \($0)")
            }
            XCTAssertEqual(message, "entity declarations are not allowed")
        }
    }

    // MARK: Real profiles (opt-in)

    /// Loads every `.goxlr` in $XLR_SAMPLE_PROFILES: the installed, damaged
    /// Default.goxlr must be rejected and every other file must parse.
    func testSampleProfiles() throws {
        guard let path = ProcessInfo.processInfo.environment["XLR_SAMPLE_PROFILES"], !path.isEmpty else {
            throw XCTSkip("set XLR_SAMPLE_PROFILES to a folder of .goxlr files")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "goxlr" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var parsed = 0, rejected = 0
        for url in files {
            let name = url.lastPathComponent
            if name == "Default.goxlr" {
                XCTAssertThrowsError(try OfficialProfile.load(contentsOf: url), name) {
                    guard case .damaged? = $0 as? OfficialProfileError else { return XCTFail("\(name): \($0)") }
                    print("XLR_SAMPLE_PROFILES: \(name) rejected: \($0)")
                }
                rejected += 1
                continue
            }
            let profile = try OfficialProfile.load(contentsOf: url)
            XCTAssertNotNil(profile.version, name)
            XCTAssertNotNil(profile.devicePID, name)
            XCTAssertFalse(profile.levels.isEmpty, name)
            XCTAssertTrue(profile.levels.values.allSatisfy { (0...255).contains($0) }, name)
            XCTAssertEqual(Set(profile.routing.keys), Set(RoutingInput.allCases), name)
            XCTAssertEqual(profile.faders.count, 4, name)
            XCTAssertTrue(profile.faders.values.allSatisfy { $0.channel != nil && $0.knownOffStyle != nil }, name)
            XCTAssertEqual(profile.muteButtons.count, 4, name)
            XCTAssertTrue(profile.muteButtons.values.allSatisfy { $0.muteFunction != nil && $0.button.knownOffStyle != nil }, name)
            let buttons = profile.muteButtons.values.map(\.button)
                + [profile.cough?.button, profile.bleep, profile.logo, profile.globalColour].compactMap { $0 }
            XCTAssertEqual(buttons.count, 8, name)
            XCTAssertTrue(buttons.allSatisfy { $0.colour0?.rgb != nil && $0.colour1?.rgb != nil }, name)
            XCTAssertEqual(profile.undecoded, [], name)
            parsed += 1
        }
        print("XLR_SAMPLE_PROFILES: \(parsed) parsed, \(rejected) rejected")
        XCTAssertGreaterThan(parsed, 0)
    }
}
