// The Mini's lights: the colour map (0x803) and animations (0x816).
//
// Layout from goxlr-utility `colouring.rs` (commit 49ab4e4, read for facts):
// each colour is 4 bytes, B G R and 0 (the order and zero byte the camera
// confirmed, L-122), at slot × 4. Firmware with animations takes a 520-byte
// map, older firmware 328 bytes with some targets elsewhere. The map can't be
// read back, and a write replaces every slot, so the app only sends a map in
// which every light the Mini has is set. The logo's colours also go to slots
// 8–9 (goxlr-utility's "internal light", filled from the logo); other slots
// are written as 0 (the full GoXLR's effects, sampler, encoders, scribbles).

import Foundation

/// A light with two colours. Faders: in the two-colour display, colour 0 lights
/// the strip below the knob and colour 1 above it (L-137). Buttons: on and off
/// (goxlr-utility: colour 0 is the active colour).
public enum LightTarget: String, CaseIterable, Codable, Sendable {
    case fader1, fader2, fader3, fader4, mute1, mute2, mute3, mute4, bleep, cough, logo

    public var title: String {
        switch self {
        case .fader1, .fader2, .fader3, .fader4: return "Fader \(["A", "B", "C", "D"][index]) strip"
        case .mute1, .mute2, .mute3, .mute4: return "Mute \(["A", "B", "C", "D"][index])"
        case .bleep: return "Bleep"
        case .cough: return "Cough"
        case .logo: return "Logo"
        }
    }

    public var colourTitles: (String, String) {
        switch self {
        case .fader1, .fader2, .fader3, .fader4: return ("Below knob", "Above knob")
        case .logo: return ("Colour", "Second colour")
        default: return ("On", "Off")
        }
    }

    private var index: Int {
        switch self {
        case .fader1, .mute1: return 0
        case .fader2, .mute2: return 1
        case .fader3, .mute3: return 2
        case .fader4, .mute4: return 3
        default: return 0
        }
    }

    /// First slot of the target's two colours.
    func slot(wideMap: Bool) -> Int {
        switch self {
        case .mute1, .mute2, .mute3, .mute4: return 12 + 2 * index
        case .fader1, .fader2, .fader3, .fader4: return wideMap ? 20 + 14 * index : 20 + 2 * index
        case .bleep: return wideMap ? 126 : 78
        case .cough: return wideMap ? 128 : 80
        case .logo: return 10
        }
    }
}

public struct Lighting: Codable, Equatable, Sendable {
    /// Two colours per target.
    public var colours: [LightTarget: [RGB]]

    public init(colours: [LightTarget: [RGB]] = [:]) { self.colours = colours }

    /// Every light in one colour (both colours of each).
    public static func uniform(_ colour: RGB) -> Lighting {
        var lighting = Lighting()
        for target in LightTarget.allCases { lighting.colours[target] = [colour, colour] }
        return lighting
    }

    public var isComplete: Bool { LightTarget.allCases.allSatisfy { colours[$0]?.count == 2 } }

    /// The 0x803 payload, or nil until every light is set.
    public func colourMap(features: FirmwareFeatures) -> [UInt8]? {
        guard isComplete else { return nil }
        let wide = features.animations
        var bytes = [UInt8](repeating: 0, count: wide ? 520 : 328)
        var placements = LightTarget.allCases.map { ($0.slot(wideMap: wide), colours[$0] ?? []) }
        placements.append((8, colours[.logo] ?? []))
        for (slot, pair) in placements {
            for (offset, colour) in pair.enumerated() {
                let start = (slot + offset) * 4
                bytes[start] = colour.blue
                bytes[start + 1] = colour.green
                bytes[start + 2] = colour.red
                bytes[start + 3] = 0
            }
        }
        return bytes
    }
}

/// 0x816 modes (goxlr-utility declaration order). The Mini refuses Ripple.
public enum AnimationMode: UInt8, CaseIterable, Codable, Sendable {
    case retroRainbow = 0, rainbowDark, rainbowBright, simple, ripple, none

    public var title: String {
        switch self {
        case .retroRainbow: return "Retro rainbow"
        case .rainbowDark: return "Rainbow (dark)"
        case .rainbowBright: return "Rainbow (bright)"
        case .simple: return "Simple"
        case .ripple: return "Ripple"
        case .none: return "None"
        }
    }

    public static func available(on model: DeviceModel) -> [AnimationMode] {
        model == .full ? allCases : allCases.filter { $0 != .ripple }
    }
}

public enum Waterfall: UInt8, CaseIterable, Codable, Sendable {
    case down = 0, up, off

    public var title: String { ["Down", "Up", "Off"][Int(rawValue)] }
}

public struct Animation: Codable, Equatable, Sendable {
    public var mode: AnimationMode
    /// 0–100; their meaning per mode isn't documented.
    public var modifier1: UInt8
    public var modifier2: UInt8
    public var waterfall: Waterfall

    public init(mode: AnimationMode = .none, modifier1: UInt8 = 0, modifier2: UInt8 = 0, waterfall: Waterfall = .off) {
        self.mode = mode
        self.modifier1 = min(modifier1, 100)
        self.modifier2 = min(modifier2, 100)
        self.waterfall = waterfall
    }

    /// {enabled, mode, modifier 1, modifier 2, waterfall}.
    public var payload: [UInt8] {
        [mode == .none ? 0 : 1, mode.rawValue, min(modifier1, 100), min(modifier2, 100), waterfall.rawValue]
    }
}
