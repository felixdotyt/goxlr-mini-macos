// The control protocol codec (docs/protocol/SPEC.md). Byte-tested against
// Tests/Vectors/*.json, the same vectors check_vectors.py checks.

import Foundation

public enum DCP {
    public static let headerLength = 16
    public static let magic: (UInt32, UInt32) = (0x0406_1973, 0x1810_1966)

    public static func opcode(category: UInt32, index: UInt32) -> UInt32 {
        (category & 0xFFF) << 12 | (index & 0xFFF)
    }

    /// SPEC.md section 3.
    public static func encodeRequest(category: UInt32, index: UInt32, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerLength + payload.count)
        bytes.appendLE(opcode(category: category, index: index))
        bytes.appendLE(UInt16(payload.count))
        bytes.appendLE(sequence)
        bytes.appendLE(UInt32(0))
        bytes.appendLE(UInt32(0))
        return bytes + payload
    }

    /// SPEC.md section 3: the checks run in this order, and the first failure is the result.
    public static func parseReply(_ bytes: [UInt8], category: UInt32, index: UInt32, sequence: UInt16,
                                  maxPayload: Int) -> Result<[UInt8], DCPError> {
        guard bytes.count >= headerLength else { return .failure(.replyTooShort) }
        guard bytes.le32(at: 0) == opcode(category: category, index: index) else { return .failure(.opcodeMismatch) }
        guard bytes.le16(at: 6) == sequence else { return .failure(.sequenceMismatch) }
        let length = Int(bytes.le16(at: 4))
        guard length + headerLength == bytes.count else { return .failure(.lengthMismatch) }
        guard length <= maxPayload else { return .failure(.replyTooLarge) }
        let status = bytes.le32(at: 8)
        guard status == 0 else { return .failure(.dcpStatus(DCPStatus(rawValue: status))) }
        return .success(Array(bytes[headerLength...]))
    }
}

/// SPEC.md section 6, the error algebra.
public enum DCPError: Error, Equatable, Sendable {
    case transfer(Int32)
    case stall
    case waitTimeout
    case replyTooShort
    case opcodeMismatch
    case sequenceMismatch
    case lengthMismatch
    case replyTooLarge
    case dcpStatus(DCPStatus)
    case stopping
}

/// DCP status codes (SPEC.md section 6; the numbering is medium confidence, L-031).
public struct DCPStatus: RawRepresentable, Equatable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    static let names = ["success", "error", "timeout", "invalid command sequence", "invalid opcode category",
                        "invalid state", "max transfer size exceeded", "invalid opcode index", "invalid argument",
                        "not supported", "invalid response sequence"]

    public var name: String { rawValue < Self.names.count ? Self.names[Int(rawValue)] : "unknown" }
    public var description: String { "\(rawValue) (\(name))" }
}

/// SPEC.md section 1.
public struct USBSetup: Equatable, Sendable {
    public var bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, wLength: UInt16

    public var bytes: [UInt8] {
        var bytes = [bmRequestType, bRequest]
        bytes.appendLE(wValue)
        bytes.appendLE(wIndex)
        bytes.appendLE(wLength)
        return bytes
    }

    public static let readGlobalData = USBSetup(bmRequestType: 0xC1, bRequest: 0, wValue: 0, wIndex: 0, wLength: 24)
    public static let reset = USBSetup(bmRequestType: 0x41, bRequest: 1, wValue: 0, wIndex: 0, wLength: 0)
    public static func sendCommand(payloadLength: Int) -> USBSetup {
        USBSetup(bmRequestType: 0x41, bRequest: 2, wValue: 0, wIndex: 0, wLength: UInt16(DCP.headerLength + payloadLength))
    }
    public static func readReply(maxPayload: Int) -> USBSetup {
        USBSetup(bmRequestType: 0xC1, bRequest: 3, wValue: 0, wIndex: 0, wLength: UInt16(maxPayload + DCP.headerLength))
    }
    /// UAC2 SET CUR sampling frequency on clock 41, data u32 48000 (L-055).
    public static let setSampleRate48k = USBSetup(bmRequestType: 0x21, bRequest: 1, wValue: 0x0100, wIndex: 0x2900, wLength: 4)
}

/// SPEC.md section 2.
public struct GlobalData: Equatable, Sendable {
    public var dcpVersion: UInt32
    public var maxPayload: UInt32
    public var resetWithBRequest1: Bool { dcpVersion > 1 }

    public enum Failure: Error, Equatable { case badLength, badMagic }

    public static func parse(_ bytes: [UInt8]) -> Result<GlobalData, Failure> {
        guard bytes.count == 24 else { return .failure(.badLength) }
        guard bytes.le32(at: 0) == DCP.magic.0, bytes.le32(at: 4) == DCP.magic.1 else { return .failure(.badMagic) }
        return .success(GlobalData(dcpVersion: bytes.le32(at: 8), maxPayload: bytes.le32(at: 16)))
    }
}

/// SPEC.md section 5: a UAC2 interrupt data message.
public struct InterruptMessage: Equatable, Sendable {
    public var vendor: Bool
    public var responseReady: Bool
    public var eventFlags: UInt32
    public var attribute: UInt8, wValue: UInt16, wIndex: UInt16
    /// SPEC.md reads input state on any vendor message that isn't a reply (L-064).
    public var readInputState: Bool { vendor && !responseReady }

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        vendor = bytes[0] == 0x01
        attribute = bytes[1]
        wValue = bytes.le16(at: 2)
        wIndex = bytes.le16(at: 4)
        let v = UInt32(wValue) | UInt32(wIndex) << 16
        responseReady = vendor && v & 1 != 0
        eventFlags = vendor ? v & 0xFFE0_0000 : 0
    }
}

/// SPEC.md section 9: the 0x80F:0 reply.
public struct Versions: Equatable, Sendable {
    public var firmware: [UInt32]   // major, minor, patch, build
    public var fpgaCount: UInt32
    public var diceBuild: UInt32
    public var diceVersion: [UInt32] // major, minor, patch

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 24 else { return nil }
        let w = (0..<6).map { bytes.le32(at: 4 * $0) }
        firmware = [w[0] >> 12 & 0xF, w[0] >> 8 & 0xF, w[0] & 0xFF, w[1]]
        fpgaCount = w[3]
        diceBuild = w[4]
        diceVersion = [w[5] >> 20 & 0xF, w[5] >> 12 & 0xFF, w[5] & 0xFFF]
    }

    public var firmwareText: String { firmware.map(String.init).joined(separator: ".") }
}

/// SPEC.md section 10: the 0x800:0 reply.
public struct InputState: Equatable, Sendable {
    public var buttons: UInt32       // masked with 0x3FFFFFFF, as the app
    public var encoders: [Int8]      // Pitch, Gender, Reverb, Echo
    public var faders: [UInt8]       // A-D
    public var pressed: [Int] { (0..<30).filter { buttons >> $0 & 1 != 0 } }

    public init?(_ bytes: [UInt8]) {
        guard bytes.count == 12 else { return nil }
        buttons = bytes.le32(at: 0) & 0x3FFF_FFFF
        encoders = bytes[4..<8].map { Int8(bitPattern: $0) }
        faders = Array(bytes[8..<12])
    }

    public init(buttons: UInt32, encoders: [Int8], faders: [UInt8]) {
        self.buttons = buttons & 0x3FFF_FFFF
        self.encoders = encoders
        self.faders = faders
    }

    public var bytes: [UInt8] {
        var bytes = [UInt8]()
        bytes.appendLE(buttons)
        return bytes + encoders.map { UInt8(bitPattern: $0) } + faders
    }
}

/// The 0x80F:1 reply: the serial is a NUL-terminated string in the first 24
/// bytes (commands.md). Device identity: show it, never log or store it.
public enum SerialReply {
    public static func serial(_ bytes: [UInt8]) -> String {
        let field = bytes.prefix(24).prefix { $0 != 0 }
        return String(decoding: field.map { (0x20..<0x7F).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func le16(at offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }

    func le32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << (8 * $1) }
    }
}
