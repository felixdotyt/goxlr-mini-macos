// The mic on the XLR (or TRS) input and its gain and gate, as the user saved
// them, and what the helper sends for them when the driver attaches.

import Foundation

public enum MicType: String, CaseIterable, Sendable {
    case dynamic, condenser, jack

    /// Only a condenser mic gets 48 V phantom power.
    public var phantomPower: Bool { self == .condenser }

    public var title: String {
        switch self {
        case .dynamic: return "Dynamic"
        case .condenser: return "Condenser (48 V)"
        case .jack: return "TRS jack"
        }
    }

    /// The 0x80B gain key for this input. The Mini applies whichever gain key
    /// was written last (LEDGER L-126), so the helper writes this type's key.
    var gainKey: UInt32 {
        switch self {
        case .dynamic: return 0x001
        case .condenser: return 0x002
        case .jack: return 0x003
        }
    }
}

/// The saved mic settings; nil leaves the device's own value. The ranges are
/// what was tested on the Mini (gain L-126 and L-138, gate L-128), not
/// necessarily the device's limits.
public struct MicSettings: Equatable, Sendable {
    public static let gainRange = 0...72
    public static let gateRange = -59...(-20)

    public var type: MicType?
    /// Input gain in dB, for `type`'s gain key. Set through the initialiser,
    /// which clamps it.
    public private(set) var gain: Int?
    /// Noise-gate threshold in dB; the lowest value lets everything through.
    public private(set) var gateThreshold: Int?

    public init(type: MicType? = nil, gain: Int? = nil, gateThreshold: Int? = nil) {
        self.type = type
        self.gain = gain.map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }
        self.gateThreshold = gateThreshold.map { min(max($0, Self.gateRange.lowerBound), Self.gateRange.upperBound) }
    }
}

public enum MicSetup {
    public static let category: UInt32 = 0x80B
    public static let index: UInt32 = 0
    static let micTypeKey: UInt32 = 0x000
    static let gateThresholdKey: UInt32 = 0x30200

    /// MicType (SPEC.md section 8): 1 turns 48 V on, a hardware-risk value only
    /// team-signed clients may send; 0 turns it off.
    public static func phantomPayload(on: Bool) -> [UInt8] { pair(micTypeKey, on ? 1 : 0) }

    /// Gain in dB, as a u16 in the upper half of the value (commands.md).
    public static func gainPayload(type: MicType, dB: Int) -> [UInt8] {
        pair(type.gainKey, UInt32(min(max(dB, MicSettings.gainRange.lowerBound), MicSettings.gainRange.upperBound)) << 16)
    }

    /// Gate threshold in dB, as an f32.
    public static func gatePayload(dB: Int) -> [UInt8] { pair(gateThresholdKey, Float(dB).bitPattern) }

    /// What to send when the driver becomes ready, as one 0x80B command. The
    /// Mini turns 48 V on at every power-up (L-130), so a saved mic that
    /// mustn't get it is switched off first. This never turns 48 V on (that
    /// needs the user's confirmation). Gain needs a saved type; nothing saved
    /// sends nothing.
    public static func payloadOnAttach(_ settings: MicSettings) -> [UInt8]? {
        var payload = [UInt8]()
        if let type = settings.type, !type.phantomPower { payload += phantomPayload(on: false) }
        if let type = settings.type, let gain = settings.gain { payload += gainPayload(type: type, dB: gain) }
        if let gate = settings.gateThreshold { payload += gatePayload(dB: gate) }
        return payload.isEmpty ? nil : payload
    }

    private static func pair(_ key: UInt32, _ value: UInt32) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.appendLE(key)
        bytes.appendLE(value)
        return bytes
    }
}

/// The 0x80C mic level reply: a u16, linear in amplitude (LEDGER L-135: 15 dB
/// more gain raised it 5.9 times). It reads like the peak since the last read;
/// full scale is taken as 0x0FFF, the largest value seen (inferred).
public struct MicLevel: Equatable, Sendable {
    public static let fullScale = 0x0FFF
    public var raw: UInt16

    public init?(_ payload: [UInt8]) {
        guard payload.count == 2 else { return nil }
        raw = UInt16(payload[0]) | UInt16(payload[1]) << 8
    }

    /// dB below full scale, floored at -90.
    public var dBFS: Double {
        guard raw > 0 else { return -90 }
        return max(-90, 20 * log10(Double(min(Int(raw), Self.fullScale)) / Double(Self.fullScale)))
    }
}

public extension XLRDevice {
    func micLevel() throws -> Result<MicLevel, CommandFailure> {
        let outcome = try command(category: 0x80C, index: 0, payload: [])
        guard case .ok(let payload, _) = outcome else { return .failure(outcome.failure ?? .badPayload) }
        return MicLevel(payload).map { .success($0) } ?? .failure(.badPayload)
    }
}
