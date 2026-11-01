// The mixer model's commands and its host-side button behaviour.

import XCTest
@testable import GoXLRKit

final class MixerModelTests: XCTestCase {
    private func model() -> MixerModel {
        var state = MixerState()
        state.faders = [.a: .mic, .b: .music, .c: .chat, .d: .system]
        state.routing[.music] = [.headphones, .broadcast]
        state.routing[.mic] = [.broadcast, .chatMic]
        var mixer = MixerModel(state: state)
        _ = mixer.applyAll()
        return mixer
    }

    private func light(_ commands: [DeviceCommand], _ button: Button) -> ButtonLight? {
        guard case .buttonLights(let bytes)? = commands.last(where: { if case .buttonLights = $0 { return true }; return false })
        else { return nil }
        return ButtonLight(rawValue: bytes[Int(button.rawValue)])
    }

    func testEncodings() {
        XCTAssertEqual(DeviceCommand.volume(.music, 255).payload, [0xFF])
        XCTAssertEqual(DeviceCommand.volume(.music, 255).index, 7)
        XCTAssertEqual(DeviceCommand.fader(.a, .music).payload, [7, 0, 0, 0])   // L-123
        XCTAssertEqual(DeviceCommand.mute(.music, true).category, 0x809)
        XCTAssertEqual(DeviceCommand.faderDisplay(.a, gradient: false, meter: true).payload, [0, 1])
        // L-123: Music L row 14 byte 5, Music R row 15 byte 7.
        let rows = Routing.rows(for: .music, to: [.broadcast], features: .testedMini)
        var left = [UInt8](repeating: 0, count: 22), right = left
        left[5] = 0x20
        right[7] = 0x20
        XCTAssertEqual(rows, [.routingRow(index: 14, bytes: left), .routingRow(index: 15, bytes: right)])
        XCTAssertEqual(Routing.rows(for: .mic, to: [], features: FirmwareFeatures(animations: true, submixes: true, mix2: true))
            .first?.payload.count, 26)
    }

    func testFirmwareGates() {
        XCTAssertEqual(FirmwareFeatures.testedMini, FirmwareFeatures(animations: true, submixes: false, mix2: false))
        XCTAssertTrue(FirmwareFeatures(model: .mini, firmware: [1, 3, 0, 0]).mix2)
        XCTAssertFalse(FirmwareFeatures(model: .full, firmware: [1, 4, 9, 9]).mix2)
        XCTAssertTrue(FirmwareFeatures(model: .full, firmware: [1, 4, 2, 107]).submixes)
    }

    func testFaderMuteToAllAndBack() {
        var mixer = model()
        let mute = mixer.handle(.up(.fader2Mute, holdHandled: false))
        XCTAssertTrue(mute.contains(.mute(.music, true)))
        XCTAssertEqual(light(mute, .fader2Mute), .colour1)
        XCTAssertEqual(mixer.muteState(.b), .mutedToAll(blink: false))
        let unmute = mixer.handle(.up(.fader2Mute, holdHandled: false))
        XCTAssertTrue(unmute.contains(.mute(.music, false)))
        XCTAssertEqual(light(unmute, .fader2Mute), .dimmedColour1)
        // A press does nothing until release; a release after a hold does nothing either.
        XCTAssertEqual(mixer.handle(.down(.fader2Mute)), [])
        XCTAssertEqual(mixer.handle(.held(.fader2Mute)).first, .mute(.music, true))
        XCTAssertEqual(mixer.muteState(.b), .mutedToAll(blink: true))
        XCTAssertEqual(mixer.handle(.up(.fader2Mute, holdHandled: true)), [])
    }

    func testMuteToStreamRemovesOnlyThatOutput() {
        var mixer = model()
        _ = mixer.setMuteFunction(.b, .toStream)
        let commands = mixer.toggleMute(.b)
        XCTAssertFalse(commands.contains(.mute(.music, true)))
        XCTAssertEqual(commands.first, Routing.rows(for: .music, to: [.headphones], features: .testedMini).first)
        XCTAssertEqual(mixer.muteState(.b), .mutedToX)
        // Holding while muted to stream mutes to all and restores the routing.
        let held = mixer.handle(.held(.fader2Mute))
        XCTAssertTrue(held.contains(.mute(.music, true)))
        XCTAssertTrue(held.contains(Routing.rows(for: .music, to: [.headphones, .broadcast], features: .testedMini)[0]))
    }

    func testMuteToXWithoutKnownRoutingFallsBackToAll() {
        var mixer = model()
        _ = mixer.setMuteFunction(.c, .toStream)   // chat routing is unknown
        XCTAssertTrue(mixer.toggleMute(.c).contains(.mute(.chat, true)))
    }

    func testUnknownFaderChannelDoesNothing() {
        var mixer = MixerModel()
        XCTAssertEqual(mixer.handle(.up(.fader1Mute, holdHandled: false)), [])
        XCTAssertEqual(mixer.muteState(.a), .unmuted)
    }

    func testCoughHoldMode() {
        var mixer = model()
        let press = mixer.handle(.down(.cough))
        XCTAssertTrue(press.contains(.mute(.mic, true)))
        XCTAssertEqual(light(press, .cough), .colour1)
        XCTAssertTrue(mixer.handle(.up(.cough, holdHandled: false)).contains(.mute(.mic, false)))
    }

    func testCoughToggleModeAndHold() {
        var mixer = model()
        _ = mixer.setCough(CoughSettings(function: .all, toggle: true))
        XCTAssertEqual(mixer.handle(.down(.cough)), [])
        XCTAssertTrue(mixer.handle(.up(.cough, holdHandled: false)).contains(.mute(.mic, true)))
        XCTAssertTrue(mixer.handle(.up(.cough, holdHandled: false)).contains(.mute(.mic, false)))
        // Hold: mute to all and flash; the release after it changes nothing.
        _ = mixer.handle(.down(.cough))
        let held = mixer.handle(.held(.cough))
        XCTAssertTrue(held.contains(.mute(.mic, true)))
        XCTAssertEqual(light(held, .cough), .flashing)
        XCTAssertEqual(mixer.handle(.up(.cough, holdHandled: true)), [])
    }

    func testCoughToChatUsesRouting() {
        var mixer = model()
        _ = mixer.setCough(CoughSettings(function: .toChat, toggle: false))
        let press = mixer.handle(.down(.cough))
        XCTAssertFalse(press.contains(.mute(.mic, true)))
        XCTAssertEqual(press.first, Routing.rows(for: .mic, to: [.broadcast], features: .testedMini).first)
    }

    func testMicStaysMutedWhileTheFaderMutesIt() {
        var mixer = model()
        _ = mixer.toggleMute(.a)                        // fader A = Mic, muted to all
        _ = mixer.handle(.down(.cough))                 // already muted: no second 0x809
        let release = mixer.handle(.up(.cough, holdHandled: false))
        XCTAssertFalse(release.contains(.mute(.mic, false)))
        XCTAssertTrue(mixer.toggleMute(.a).contains(.mute(.mic, false)))
    }

    func testBleepLightsOnlyWhileDown() {
        var mixer = model()
        XCTAssertEqual(light(mixer.handle(.down(.bleep)), .bleep), .colour1)
        XCTAssertEqual(light(mixer.handle(.up(.bleep, holdHandled: false)), .bleep), .dimmedColour1)
    }

    func testReassigningAMutedFaderUnmutesItFirst() {
        var mixer = model()
        _ = mixer.toggleMute(.b)
        let commands = mixer.setFader(.b, .game)
        XCTAssertEqual(commands.prefix(1), [.mute(.music, false)])
        XCTAssertTrue(commands.contains(.fader(.b, .game)))
    }

    func testTracker() {
        var tracker = ButtonTracker(holdTime: 0.5)
        let bit = UInt32(1) << Button.fader1Mute.rawValue
        XCTAssertEqual(tracker.update(pressed: bit, at: 0), [.down(.fader1Mute)])
        XCTAssertEqual(tracker.update(pressed: bit, at: 0.3), [])
        XCTAssertEqual(tracker.update(pressed: bit, at: 0.6), [.held(.fader1Mute)])
        XCTAssertEqual(tracker.update(pressed: bit, at: 0.9), [])
        XCTAssertEqual(tracker.update(pressed: 0, at: 1.0), [.up(.fader1Mute, holdHandled: true)])
        XCTAssertEqual(tracker.update(pressed: bit | 1 << Button.bleep.rawValue, at: 2), [.down(.fader1Mute), .down(.bleep)])
        XCTAssertEqual(tracker.update(pressed: 0, at: 2.1), [.up(.fader1Mute, holdHandled: false), .up(.bleep, holdHandled: false)])
    }

    func testApplyAllSendsWhatIsSet() {
        var mixer = model()
        _ = mixer.setVolume(.music, 200)
        let commands = mixer.applyAll()
        XCTAssertTrue(commands.contains(.fader(.a, .mic)))
        XCTAssertTrue(commands.contains(.volume(.music, 200)))
        XCTAssertFalse(commands.contains { if case .volume(.game, _) = $0 { return true }; return false })
        XCTAssertEqual(commands.filter { if case .routingRow = $0 { return true }; return false }.count, 4)
        XCTAssertFalse(commands.contains { if case .buttonLights = $0 { return true }; return false })
    }

    // Review findings: profile swaps, re-attach, no-op changes, Mix2, decoding.

    func testApplyingAProfileReleasesMutesFirst() {
        var mixer = model()
        _ = mixer.toggleMute(.b)                          // Music muted to all
        var next = mixer.state
        next.faders[.b] = .game
        let commands = mixer.apply(next)
        XCTAssertEqual(commands.first, .mute(.music, false))
        XCTAssertFalse(commands.contains(.mute(.music, true)))
        XCTAssertEqual(mixer.muteState(.b), .unmuted)
        XCTAssertTrue(mixer.toggleMute(.b).contains(.mute(.game, true)))
    }

    func testApplyingAProfileRestoresCoughRouting() {
        var mixer = model()
        _ = mixer.setCough(CoughSettings(function: .toStream, toggle: true))
        _ = mixer.handle(.up(.cough, holdHandled: false))  // mic out of the stream
        var next = mixer.state
        next.cough = CoughSettings(function: .toChat, toggle: true)
        _ = mixer.apply(next)
        XCTAssertEqual(mixer.cough, .unmuted)
    }

    func testReleaseAllMutes() {
        var mixer = model()
        _ = mixer.setMuteFunction(.b, .toStream)
        _ = mixer.toggleMute(.b)                          // Music out of the stream
        _ = mixer.toggleMute(.a)                          // Mic muted to all
        let commands = mixer.releaseAllMutes()
        XCTAssertTrue(commands.contains(.mute(.mic, false)))
        XCTAssertTrue(commands.contains(Routing.rows(for: .music, to: [.headphones, .broadcast], features: .testedMini)[0]))
        XCTAssertEqual(mixer.mutedChannels, [])
        XCTAssertEqual(mixer.releaseAllMutes(), [])
    }

    func testButtonsWaitForSettingsSentSinceAttach() {
        var mixer = model()
        mixer.deviceAttached()                           // power cycle: the device lost the faders
        XCTAssertEqual(mixer.toggleMute(.b), [])
        _ = mixer.applyAssignments()
        XCTAssertTrue(mixer.toggleMute(.b).contains(.mute(.music, true)))
        // Routing not re-sent: mute-to-X falls back to mute to all.
        mixer.deviceAttached()
        var fadersOnly = mixer
        _ = fadersOnly.setFader(.b, .music)
        _ = fadersOnly.setMuteFunction(.b, .toStream)
        XCTAssertTrue(fadersOnly.toggleMute(.b).contains(.mute(.music, true)))
    }

    // L-142: after a power-up the faders read 0 and their channels stay at 0
    // until each fader moves.
    func testFaderReportsCountOnceTheFaderMoves() {
        var mixer = model()
        mixer.deviceAttached()
        XCTAssertFalse(mixer.faderReport([0, 0, 0, 0]))  // assignments not sent since attach
        _ = mixer.applyAssignments()
        XCTAssertFalse(mixer.faderReport([0, 0, 0, 0]))  // first report: not moved yet
        XCTAssertFalse(mixer.faderReport([0, 0, 0, 0]))
        XCTAssertTrue(mixer.faderReport([0, 0, 0, 189]))
        XCTAssertEqual(mixer.state.volumes, [.system: 189])
        XCTAssertTrue(mixer.faderReport([0, 0, 0, 0]))   // moved to the bottom: a real 0
        XCTAssertEqual(mixer.state.volumes[.system], 0)
        // A new channel on the fader waits for the fader to move again.
        _ = mixer.setFader(.d, .game)
        XCTAssertFalse(mixer.faderReport([0, 0, 0, 0]))
        XCTAssertFalse(mixer.faderReport([0, 0, 0, 0]))
        XCTAssertTrue(mixer.faderReport([0, 0, 0, 40]))
        XCTAssertEqual(mixer.state.volumes, [.system: 0, .game: 40])
    }

    func testFaderVolumesAreSentAtAttach() {
        var mixer = model()
        _ = mixer.setVolume(.system, 189)
        _ = mixer.setVolume(.headphones, 200)              // not on a fader
        mixer.deviceAttached()
        XCTAssertEqual(mixer.applyFaderVolumes(), [.volume(.system, 189)])
        XCTAssertTrue(mixer.applied.volumes.contains(.system))
        // The unmoved faders' reports don't overwrite the saved volume.
        _ = mixer.applyAssignments()
        XCTAssertFalse(mixer.faderReport([0, 0, 0, 0]))
        XCTAssertEqual(mixer.state.volumes[.system], 189)
    }

    func testUnchangedSettingsKeepMutes() {
        var mixer = model()
        _ = mixer.toggleMute(.b)
        XCTAssertEqual(mixer.setMuteFunction(.b, .all), [])
        XCTAssertEqual(mixer.setFader(.b, .music), [])
        XCTAssertEqual(mixer.muteState(.b), .mutedToAll(blink: false))
        _ = mixer.handle(.down(.cough))
        XCTAssertEqual(mixer.setCough(CoughSettings()), [])
        XCTAssertTrue(mixer.cough.isMuted)
    }

    func testMix2FirmwareWritesNoRouting() {
        var state = MixerState()
        state.faders = [.b: .music]
        state.routing[.music] = [.broadcast]
        state.muteFunctions[.b] = .toStream
        var mixer = MixerModel(state: state, features: FirmwareFeatures(animations: true, submixes: true, mix2: true))
        XCTAssertFalse(mixer.applyAll().contains { if case .routingRow = $0 { return true }; return false })
        XCTAssertEqual(mixer.setRouting(.music, [.headphones]), [])
        XCTAssertTrue(mixer.toggleMute(.b).contains(.mute(.music, true)))
    }

    func testOlderSavedStateDecodes() throws {
        let state = try JSONDecoder().decode(MixerState.self, from: Data(#"{"volumes":[7,200]}"#.utf8))
        XCTAssertEqual(state.volumes, [.music: 200])
        XCTAssertEqual(state.cough, CoughSettings())
    }

    func testReleasingOnMix2FirmwareWritesNoRows() {
        var mixer = model()
        _ = mixer.setMuteFunction(.b, .toStream)
        _ = mixer.toggleMute(.b)
        mixer.features = FirmwareFeatures(animations: true, submixes: true, mix2: true)
        XCTAssertFalse(mixer.releaseAllMutes().contains { if case .routingRow = $0 { return true }; return false })
    }
}
