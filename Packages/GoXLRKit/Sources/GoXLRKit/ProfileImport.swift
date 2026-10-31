// Official profile → our profile (profile-format.md "Value encodings").
//
// Carried over: channel volumes, routing, fader channels and display modes,
// mute-button functions, the inactive button style, and the Mini's colours
// when the profile sets all of them. Not carried: effects, sampler and
// scribbles (full GoXLR only), and mic settings (official mic profiles are
// separate files). Values the importer couldn't decode are skipped, so they
// stay "not set".

import Foundation

public extension OfficialProfile {
    func deviceProfile(named name: String) -> DeviceProfile {
        var mixer = MixerState()
        // Profile levels are 0–255, the 0x806 range (inferred to be the same scale).
        for (channel, level) in levels where (0...255).contains(level) { mixer.volumes[channel] = UInt8(level) }
        mixer.routing = routing
        for (fader, settings) in faders {
            if let channel = settings.channel, Channel.faderChannels.contains(channel) { mixer.faders[fader] = channel }
            if let display = settings.knownDisplay { mixer.faderDisplays[fader] = FaderDisplay(display) }
        }
        for (fader, button) in muteButtons {
            if let function = button.muteFunction { mixer.muteFunctions[fader] = function }
        }
        // One inactive style for all buttons here: the mute buttons' most common one.
        let styles = Fader.allCases.compactMap { muteButtons[$0]?.button.knownOffStyle }
        if let style = OffStyle.allCases.max(by: { a, b in styles.filter { $0 == a }.count < styles.filter { $0 == b }.count }),
           styles.contains(style) {
            mixer.offLight = ButtonLight(style)
        }
        return DeviceProfile(name: name, mixer: mixer, lighting: lighting)
    }

    /// Colour 0 and 1 of each light the Mini has; nil unless all are readable.
    var lighting: Lighting? {
        func pair(_ a: ProfileColour?, _ b: ProfileColour?) -> [RGB]? {
            guard let first = a?.rgb, let second = b?.rgb else { return nil }
            return [first, second]
        }
        var lighting = Lighting()
        for (index, fader) in Fader.allCases.enumerated() {
            lighting.colours[[.fader1, .fader2, .fader3, .fader4][index]] = pair(faders[fader]?.colour0, faders[fader]?.colour1)
            lighting.colours[[.mute1, .mute2, .mute3, .mute4][index]] =
                pair(muteButtons[fader]?.button.colour0, muteButtons[fader]?.button.colour1)
        }
        lighting.colours[.bleep] = pair(bleep?.colour0, bleep?.colour1)
        lighting.colours[.cough] = pair(cough?.button.colour0, cough?.button.colour1)
        lighting.colours[.logo] = pair(logo?.colour0, logo?.colour1)
        return lighting.isComplete ? lighting : nil
    }
}

extension FaderDisplay {
    /// 0x814 {gradient, meter}: two colours 00 00, gradient 01 00, meter 00 01 (L-122).
    init(_ style: FaderDisplayStyle) {
        switch style {
        case .twoColour: self.init(gradient: false, meter: false)
        case .gradient: self.init(gradient: true, meter: false)
        case .meter: self.init(gradient: false, meter: true)
        case .gradientMeter: self.init(gradient: true, meter: true)
        }
    }
}

extension ButtonLight {
    /// The app's off styles by name (inferred: the names match the 0x808 states).
    init(_ style: OffStyle) {
        switch style {
        case .dimmed: self = .dimmedColour1
        case .colour2: self = .colour2
        case .dimmedColour2: self = .dimmedColour2
        }
    }
}
