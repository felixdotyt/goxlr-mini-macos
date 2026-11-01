// Our profile format and the profile store.

import XCTest
@testable import GoXLRKit

final class ProfileTests: XCTestCase {
    private var store: ProfileStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("xlr-profiles-\(UUID().uuidString)")
        store = ProfileStore(directory: directory)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testRoundTrip() throws {
        var mixer = MixerState()
        mixer.volumes = [.music: 200, .mic: 255]
        mixer.faders = [.a: .mic, .b: .music]
        mixer.routing = [.music: [.headphones, .broadcast], .mic: []]
        mixer.muteFunctions = [.b: .toStream]
        mixer.cough = CoughSettings(function: .toChat, toggle: true)
        mixer.faderDisplays = [.a: FaderDisplay(gradient: false, meter: true)]
        let profile = DeviceProfile(name: "Streaming", mixer: mixer, mic: MicSettings(type: .condenser, gain: 40, gateThreshold: -59))
        try store.save(profile)
        XCTAssertEqual(try store.load("Streaming"), profile)
        XCTAssertEqual(store.names(), ["Streaming"])
        try store.delete("Streaming")
        XCTAssertEqual(store.names(), [])
    }

    func testNamesAreSortedAndOtherFilesSkipped() throws {
        for name in ["b", "A 10", "A 2"] { try store.save(DeviceProfile(name: name)) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("junk.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        XCTAssertEqual(store.names(), ["A 2", "A 10", "b"])
    }

    func testACopiedFileIsItsOwnProfile() throws {
        try store.save(DeviceProfile(name: "A"))
        try FileManager.default.copyItem(at: directory.appendingPathComponent("A.json"),
                                          to: directory.appendingPathComponent("A copy.json"))
        XCTAssertEqual(store.names(), ["A", "A copy"])
        try store.delete("A")
        XCTAssertEqual(try store.load("A copy").name, "A copy")
        try store.delete("A copy")
        XCTAssertEqual(store.names(), [])
    }

    func testFilesThatDontMapBackAreSkipped() throws {
        try store.save(DeviceProfile(name: "A"))
        for odd in [" A.json", ".hidden.json", "x:y.json"] {
            try FileManager.default.copyItem(at: directory.appendingPathComponent("A.json"), to: directory.appendingPathComponent(odd))
        }
        XCTAssertEqual(store.names(), ["A"])
        XCTAssertTrue(store.exists("A"))
        XCTAssertFalse(store.exists("B"))
    }

    func testBadNamesAreRefused() {
        for name in ["", "  ", ".hidden", "a/b", "../up", "x:y", String(repeating: "é", count: 101)] {
            XCTAssertThrowsError(try store.save(DeviceProfile(name: name)), name)
        }
    }

    func testNewerFormatIsRefused() throws {
        try store.save(DeviceProfile(name: "future"))
        let url = directory.appendingPathComponent("future.json")
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 9")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load("future")) { XCTAssertEqual($0 as? ProfileStoreError, .newerFormat(9)) }
    }

    func testPartialProfiles() throws {
        var processing = MicProcessing()
        processing.gateAttack = 3
        try store.save(DeviceProfile(name: "Mic only", mic: MicSettings(type: .dynamic, gain: 60), processing: processing))
        let loaded = try store.load("Mic only")
        XCTAssertNil(loaded.mixer)
        XCTAssertEqual(loaded.parts, [.mic])
        XCTAssertEqual(DeviceProfile(name: "x", mixer: MixerState(), lighting: .uniform(RGB(red: 1, green: 2, blue: 3))).parts,
                       [.mixer, .lighting])
        XCTAssertEqual(DeviceProfile(name: "empty").parts, [])
        // A profile saved before parts existed has a mixer.
        let old = #"{"formatVersion":1,"name":"old","mixer":{"faders":[0,0]},"mic":{}}"#
        let decoded = try JSONDecoder().decode(DeviceProfile.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.parts, [.mixer])
        XCTAssertEqual(decoded.mixer?.faders, [.a: .mic])
    }

    func testDefaultProfiles() throws {
        let defaults = DeviceProfile.defaults
        XCTAssertEqual(Set(defaults.map(\.name)).count, defaults.count)
        XCTAssertTrue(defaults.allSatisfy { !$0.parts.isEmpty })
        for profile in defaults where profile.lighting != nil {
            XCTAssertNotNil(profile.lighting?.colourMap(features: .testedMini), profile.name)
        }
        // The computer's audio (macOS plays into System) reaches the headphones.
        let layout = try XCTUnwrap(defaults.first { $0.name == "Default Layout" }?.mixer)
        for input in [RoutingInput.system, .game, .chat, .music, .sample] {
            XCTAssertEqual(layout.routing[input], [.headphones], input.title)
        }
        XCTAssertEqual(try store.addMissing(defaults), defaults.map(\.name))
        XCTAssertEqual(Set(store.names()), Set(defaults.map(\.name)))
        for profile in defaults { XCTAssertEqual(try store.load(profile.name), profile) }
        // Existing names are kept, not overwritten.
        try store.save(DeviceProfile(name: "Lights Off", mixer: MixerState()))
        try store.delete("Condenser Mic")
        XCTAssertEqual(try store.addMissing(defaults), ["Condenser Mic"])
        XCTAssertEqual(try store.load("Lights Off").parts, [.mixer])
    }

    func testImportAndExport() throws {
        XCTAssertTrue(store.isNew)
        try store.save(DeviceProfile(name: "Show", mic: MicSettings(gain: 30)))
        XCTAssertFalse(store.isNew)
        let file = directory.deletingLastPathComponent().appendingPathComponent("Show-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try store.data(for: "Show").write(to: file)
        let name = try store.importProfile(from: file)
        XCTAssertEqual(name, file.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(try store.load(name).mic.gain, 30)
        XCTAssertEqual(try store.importProfile(from: file), name + " 2")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try store.importProfile(from: file))
    }

    func testMergingProcessing() {
        var current = MicProcessing()
        current.gateAttack = 1
        current.bleepLevel = -20
        var incoming = MicProcessing()
        incoming.bleepLevel = -10
        incoming.compressorRatio = 4
        let merged = current.merging(incoming)
        XCTAssertEqual(merged.gateAttack, 1)
        XCTAssertEqual(merged.bleepLevel, -10)
        XCTAssertEqual(merged.compressorRatio, 4)
    }

    func testDecodedMicSettingsAreClamped() throws {
        let json = #"{"type":"dynamic","gain":99,"gateThreshold":-100}"#
        let mic = try JSONDecoder().decode(MicSettings.self, from: Data(json.utf8))
        XCTAssertEqual(mic, MicSettings(type: .dynamic, gain: 72, gateThreshold: -59))
    }
}
