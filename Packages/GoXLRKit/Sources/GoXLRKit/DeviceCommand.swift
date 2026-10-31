// Typed GoXLR write commands and their DCP encoding (commands.md, SPEC.md
// section 8). The driver checks every command against its policy table; these
// types only build what the table allows.

import Foundation

/// What the device's firmware supports (SPEC.md section 9; GU's gates, inferred
/// until verified).
public struct FirmwareFeatures: Equatable, Sendable {
    public var animations: Bool
    public var submixes: Bool
    /// Mix2 firmware has 26-byte routing rows instead of 22.
    public var mix2: Bool

    public init(animations: Bool, submixes: Bool, mix2: Bool) {
        self.animations = animations
        self.submixes = submixes
        self.mix2 = mix2
    }

    public init(model: DeviceModel, firmware: [UInt32]) {
        func atLeast(_ version: [UInt32]) -> Bool { firmware.lexicographicallyPrecedes(version) == false }
        let full = model == .full
        animations = atLeast(full ? [1, 3, 40, 0] : [1, 1, 8, 0])
        submixes = atLeast(full ? [1, 4, 2, 107] : [1, 2, 0, 46])
        mix2 = atLeast(full ? [1, 5, 0, 0] : [1, 3, 0, 0])
    }

    /// The Mini on firmware 1.1.8.43, as tested (LEDGER L-118).
    public static let testedMini = FirmwareFeatures(model: .mini, firmware: [1, 1, 8, 43])

    public var routingRowLength: Int { mix2 ? 26 : 22 }
}

public enum DeviceCommand: Equatable, Sendable {
    /// 0x806 bank 0: channel volume 0–255.
    case volume(Channel, UInt8)
    /// 0x809: channel muted.
    case mute(Channel, Bool)
    /// 0x805: the channel a fader controls.
    case fader(Fader, Channel)
    /// 0x804: one routing row, already encoded.
    case routingRow(index: UInt32, bytes: [UInt8])
    /// 0x808: the light state of every button, indexed by its input-state bit.
    case buttonLights([UInt8])
    /// 0x814: fader display {gradient, meter}.
    case faderDisplay(Fader, gradient: Bool, meter: Bool)
    /// 0x80B: mic parameter pairs (MicSetup).
    case micParameters([UInt8])
    /// 0x803: the whole colour map (Lighting).
    case colourMap([UInt8])
    /// 0x816: animation (Animation.payload).
    case animation([UInt8])

    public var category: UInt32 {
        switch self {
        case .volume: return 0x806
        case .mute: return 0x809
        case .fader: return 0x805
        case .routingRow: return 0x804
        case .buttonLights: return 0x808
        case .faderDisplay: return 0x814
        case .micParameters: return MicSetup.category
        case .colourMap: return 0x803
        case .animation: return 0x816
        }
    }

    public var index: UInt32 {
        switch self {
        case .volume(let channel, _), .mute(let channel, _): return channel.rawValue
        case .fader(let fader, _), .faderDisplay(let fader, _, _): return fader.rawValue
        case .routingRow(let index, _): return index
        case .buttonLights, .micParameters, .colourMap, .animation: return 0
        }
    }

    public var payload: [UInt8] {
        switch self {
        case .volume(_, let value): return [value]
        case .mute(_, let muted): return [muted ? 1 : 0]
        case .fader(_, let channel):
            var bytes = [UInt8]()
            bytes.appendLE(channel.rawValue)
            return bytes
        case .routingRow(_, let bytes), .buttonLights(let bytes), .micParameters(let bytes), .colourMap(let bytes),
             .animation(let bytes):
            return bytes
        case .faderDisplay(_, let gradient, let meter): return [gradient ? 1 : 0, meter ? 1 : 0]
        }
    }

    /// For logs: never contains device identity.
    public var summary: String {
        String(format: "0x%03x:%u <- %@", category, index, payload.map { String(format: "%02x", $0) }.joined())
    }
}

public extension XLRDevice {
    func send(_ command: DeviceCommand) throws -> CommandOutcome {
        try self.command(category: command.category, index: command.index, payload: command.payload)
    }
}

public enum Routing {
    /// The two 0x804 rows for an input routed to `outputs` (commands.md: the high
    /// byte of each output's u16 is 0x20 when routed; left row → left output).
    public static func rows(for input: RoutingInput, to outputs: Set<RoutingOutput>,
                            features: FirmwareFeatures) -> [DeviceCommand] {
        var left = [UInt8](repeating: 0, count: features.routingRowLength)
        var right = left
        for output in outputs {
            left[output.bytes.left] = 0x20
            right[output.bytes.right] = 0x20
        }
        return [.routingRow(index: input.rows.left, bytes: left), .routingRow(index: input.rows.right, bytes: right)]
    }
}
