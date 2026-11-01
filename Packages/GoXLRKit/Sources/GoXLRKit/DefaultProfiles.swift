// Profiles the helper adds on first launch (and on request), as starting
// points. Each holds only the parts it's about, so applying a mic profile
// leaves the mixer and colours alone, and the reverse.

import Foundation

public extension DeviceProfile {
    static let defaults: [DeviceProfile] = [
        DeviceProfile(name: "Default Layout", mixer: defaultMixer, lighting: defaultLighting),
        DeviceProfile(name: "Lights Off", lighting: .uniform(RGB(red: 0, green: 0, blue: 0))),
        DeviceProfile(name: "Dynamic Mic (SM7B)", mic: MicSettings(type: .dynamic, gain: 60, gateThreshold: -47),
                      processing: sm7bProcessing),
        DeviceProfile(name: "Condenser Mic", mic: MicSettings(type: .condenser, gain: 40, gateThreshold: -59)),
        DeviceProfile(name: "Mic Processing Off", mic: MicSettings(gateThreshold: -59), processing: processingOff),
    ]

    /// The official app's default fader channels; the mic to the Stream Mix and
    /// headphones, as the Mini has it at power-up (L-133, L-137). The
    /// computer's channels go to the headphones, so the Mac is heard whatever
    /// the Mini's power-up routing for them is (unknown, L-141); the Stream Mix
    /// is left for the user to add. Line In and Console are left alone.
    private static var defaultMixer: MixerState {
        var mixer = MixerState()
        mixer.faders = [.a: .mic, .b: .chat, .c: .music, .d: .system]
        mixer.routing = [.mic: [.broadcast, .headphones]]
        for input in [RoutingInput.system, .game, .chat, .music, .sample] { mixer.routing[input] = [.headphones] }
        return mixer
    }

    /// Cyan, with each fader strip dark above its knob (L-137).
    private static var defaultLighting: Lighting {
        let cyan = RGB(red: 0, green: 255, blue: 255), off = RGB(red: 0, green: 0, blue: 0)
        var lighting = Lighting.uniform(cyan)
        for target in [LightTarget.fader1, .fader2, .fader3, .fader4] { lighting.colours[target] = [cyan, off] }
        return lighting
    }

    /// The gate the user tuned by ear with an SM7B at 60 dB (2026-10-31), and a
    /// compressor set from their speech levels (L-140): threshold just under
    /// the louder quarter of speech, 3.2:1, 5 ms attack, the Mini's own 100 ms
    /// release, +3 dB make-up.
    private static var sm7bProcessing: MicProcessing {
        var processing = MicProcessing()
        processing.gateAttenuation = -28
        processing.gateAttack = 0
        processing.gateRelease = 10
        processing.compressorThreshold = -28
        processing.compressorRatio = 8
        processing.compressorAttack = 4
        processing.compressorRelease = 9
        processing.compressorMakeUp = 3
        processing.bleepLevel = -19
        return processing
    }

    /// The gate open for anything above −59 dB and only −6 dB when shut, the
    /// compressor at 1:1: as close to the dry mic as these keys allow.
    private static var processingOff: MicProcessing {
        var processing = MicProcessing()
        processing.gateAttenuation = -6
        processing.compressorRatio = 0
        processing.compressorThreshold = 0
        processing.compressorMakeUp = 0
        return processing
    }
}
