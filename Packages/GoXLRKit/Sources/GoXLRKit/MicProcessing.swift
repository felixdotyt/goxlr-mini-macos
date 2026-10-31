// The Mini's gate, compressor and bleep settings (0x80B keys; commands.md).
//
// Encodings follow goxlr-utility (read for behaviour): dB values and the
// compressor ratio are f32; gate and compressor times are f32 indexes into
// fixed time tables; the bleep level is dB × 65536 as an f32. Every setting
// here was confirmed on the Mini: gate attenuation and compressor make-up
// (L-136), the bleep level (L-137), and the gate times and the compressor's
// threshold, ratio, attack and release (L-139); the gate threshold is
// MicSettings (L-128). The Mini's EQ keys are left out: four of six bands did
// nothing measurable (L-136).

import Foundation

public struct MicProcessing: Codable, Equatable, Sendable {
    /// Gate attenuation in dB when shut: goxlr-utility's table (−61 is silence).
    public static let gateAttenuations = [-6, -7, -8, -9, -10, -11, -12, -13, -14, -15, -16, -17, -18, -19, -20, -21,
                                          -22, -23, -24, -25, -26, -27, -28, -30, -32, -61]
    /// Gate attack and release times, ms, by index.
    public static let gateTimes = Array(stride(from: 10, through: 200, by: 10)) + Array(stride(from: 250, through: 1000, by: 50))
        + Array(stride(from: 1100, through: 2000, by: 100))
    public static let compressorRatios: [Float] = [1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.5, 3.2, 4.0, 5.6, 8.0, 16.0, 32.0, 64.0]
    /// Compressor attack and release, ms, by index (0 ms attack is 0.001 ms).
    public static let compressorAttacks = [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20, 23, 26, 30, 35, 40]
    public static let compressorReleases = [0, 15, 25, 35, 45, 55, 65, 75, 85, 100, 115, 140, 170, 230, 340, 680, 1000,
                                            1500, 2000, 3000]
    public static let compressorThresholds = -40...0
    public static let makeUpGains = 0...24
    public static let bleepLevels = -34...0

    /// dB, one of `gateAttenuations`.
    public var gateAttenuation: Int?
    /// Indexes into `gateTimes`.
    public var gateAttack: Int?
    public var gateRelease: Int?
    /// dB.
    public var compressorThreshold: Int?
    /// Index into `compressorRatios`.
    public var compressorRatio: Int?
    /// Indexes into `compressorAttacks` and `compressorReleases`.
    public var compressorAttack: Int?
    public var compressorRelease: Int?
    /// dB.
    public var compressorMakeUp: Int?
    /// dB.
    public var bleepLevel: Int?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case gateAttenuation, gateAttack, gateRelease, compressorThreshold, compressorRatio, compressorAttack
        case compressorRelease, compressorMakeUp, bleepLevel
    }

    /// Decoding clamps every value into its table or range, so a hand-edited
    /// profile can't hold an index the app can't show.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Int? { try c.decodeIfPresent(Int.self, forKey: key) }
        func index(_ key: CodingKeys, _ count: Int) throws -> Int? { try value(key).map { min(max($0, 0), count - 1) } }
        func clamp(_ key: CodingKeys, _ range: ClosedRange<Int>) throws -> Int? {
            try value(key).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        gateAttenuation = try value(.gateAttenuation).map { v in Self.gateAttenuations.min { abs($0 - v) < abs($1 - v) } ?? -61 }
        gateAttack = try index(.gateAttack, Self.gateTimes.count)
        gateRelease = try index(.gateRelease, Self.gateTimes.count)
        compressorThreshold = try clamp(.compressorThreshold, Self.compressorThresholds)
        compressorRatio = try index(.compressorRatio, Self.compressorRatios.count)
        compressorAttack = try index(.compressorAttack, Self.compressorAttacks.count)
        compressorRelease = try index(.compressorRelease, Self.compressorReleases.count)
        compressorMakeUp = try clamp(.compressorMakeUp, Self.makeUpGains)
        bleepLevel = try clamp(.bleepLevel, Self.bleepLevels)
    }

    /// These settings with `other`'s set ones on top: what the device has after
    /// `other.payload` is sent.
    public func merging(_ other: MicProcessing) -> MicProcessing {
        var merged = self
        merged.gateAttenuation = other.gateAttenuation ?? gateAttenuation
        merged.gateAttack = other.gateAttack ?? gateAttack
        merged.gateRelease = other.gateRelease ?? gateRelease
        merged.compressorThreshold = other.compressorThreshold ?? compressorThreshold
        merged.compressorRatio = other.compressorRatio ?? compressorRatio
        merged.compressorAttack = other.compressorAttack ?? compressorAttack
        merged.compressorRelease = other.compressorRelease ?? compressorRelease
        merged.compressorMakeUp = other.compressorMakeUp ?? compressorMakeUp
        merged.bleepLevel = other.bleepLevel ?? bleepLevel
        return merged
    }

    enum Key: UInt32 {
        case gateAttack = 0x30400, gateRelease = 0x30600, gateAttenuation = 0x30900
        case compressorThreshold = 0x60200, compressorRatio = 0x60300, compressorAttack = 0x60400
        case compressorRelease = 0x60600, compressorMakeUp = 0x60700, bleepLevel = 0x70100
    }

    /// 0x80B pairs for every setting that is set; out-of-range values are
    /// clamped to the tables, so nothing outside them reaches the device.
    public var payload: [UInt8] {
        func index(_ value: Int?, _ count: Int) -> Float? { value.map { Float(min(max($0, 0), count - 1)) } }
        func clamp(_ value: Int?, _ range: ClosedRange<Int>) -> Float? { value.map { Float(min(max($0, range.lowerBound), range.upperBound)) } }
        let attenuation = gateAttenuation.map { value in Self.gateAttenuations.min { abs($0 - value) < abs($1 - value) } ?? -61 }
        let pairs: [(Key, Float?)] = [
            (.gateAttenuation, attenuation.map(Float.init)),
            (.gateAttack, index(gateAttack, Self.gateTimes.count)),
            (.gateRelease, index(gateRelease, Self.gateTimes.count)),
            (.compressorThreshold, clamp(compressorThreshold, Self.compressorThresholds)),
            (.compressorRatio, compressorRatio.map { Self.compressorRatios[min(max($0, 0), Self.compressorRatios.count - 1)] }),
            (.compressorAttack, index(compressorAttack, Self.compressorAttacks.count)),
            (.compressorRelease, index(compressorRelease, Self.compressorReleases.count)),
            (.compressorMakeUp, clamp(compressorMakeUp, Self.makeUpGains)),
            (.bleepLevel, clamp(bleepLevel, Self.bleepLevels).map { $0 * 65536 }),
        ]
        var bytes = [UInt8]()
        for (key, value) in pairs {
            guard let value else { continue }
            bytes.appendLE(key.rawValue)
            bytes.appendLE(value.bitPattern)
        }
        return bytes
    }
}
