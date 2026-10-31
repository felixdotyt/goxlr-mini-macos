// A minimal reader for ZIP archives whose entries are stored (method 0), the
// container of official `.goxlr` profiles (docs/protocol/profile-format.md).
// It reads the central directory and checks every entry's local header, sizes
// and CRC-32 up front, so a damaged archive is rejected whole rather than
// half-read. Compression, encryption, ZIP64 and multi-disk archives are not
// supported.

import Foundation

public struct StoredZip: Sendable {
    /// Entry names in central-directory order.
    public let names: [String]
    private let bytes: [UInt8]
    private let ranges: [String: Range<Int>]

    static let localSignature: UInt32 = 0x0403_4B50
    static let directorySignature: UInt32 = 0x0201_4B50
    static let endSignature: UInt32 = 0x0605_4B50
    static let localHeaderLength = 30, directoryHeaderLength = 46, endRecordLength = 22

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        let end = try Self.endRecord(in: bytes)
        guard bytes.le16(at: end + 4) == 0, bytes.le16(at: end + 6) == 0,
              bytes.le16(at: end + 8) == bytes.le16(at: end + 10) else {
            throw StoredZipError.unsupported("multi-disk archive")
        }
        let count = Int(bytes.le16(at: end + 10))
        let directorySize = Int(bytes.le32(at: end + 12)), directoryStart = Int(bytes.le32(at: end + 16))
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryStart != 0xFFFF_FFFF else {
            throw StoredZipError.unsupported("ZIP64 archive")
        }
        // The directory must sit between the entries and the end record.
        let directoryEnd = directoryStart + directorySize
        guard directoryEnd <= end else { throw StoredZipError.outOfBounds(offset: directoryStart) }

        var names = [String](), ranges = [String: Range<Int>]()
        var p = directoryStart
        for _ in 0..<count {
            guard p + Self.directoryHeaderLength <= directoryEnd else { throw StoredZipError.outOfBounds(offset: p) }
            guard bytes.le32(at: p) == Self.directorySignature else { throw StoredZipError.badSignature(offset: p) }
            let flags = bytes.le16(at: p + 8), method = bytes.le16(at: p + 10)
            let crc = bytes.le32(at: p + 16)
            let size = Int(bytes.le32(at: p + 20)), uncompressedSize = Int(bytes.le32(at: p + 24))
            let nameLength = Int(bytes.le16(at: p + 28))
            let next = p + Self.directoryHeaderLength + nameLength + Int(bytes.le16(at: p + 30)) + Int(bytes.le16(at: p + 32))
            guard next <= directoryEnd else { throw StoredZipError.outOfBounds(offset: p) }
            let nameBytes = bytes[p + Self.directoryHeaderLength ..< p + Self.directoryHeaderLength + nameLength]
            guard !nameBytes.isEmpty, let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw StoredZipError.badName(offset: p)
            }
            guard flags & 1 == 0 else { throw StoredZipError.unsupported("encrypted entry \(name)") }
            guard method == 0 else { throw StoredZipError.compressed(name: name, method: method) }
            guard size == uncompressedSize else { throw StoredZipError.sizeMismatch(name: name) }
            guard ranges[name] == nil else { throw StoredZipError.duplicateName(name) }

            // The local header must agree with the directory, and the entry's
            // bytes must end before the directory starts.
            let local = Int(bytes.le32(at: p + 42))
            guard local + Self.localHeaderLength <= directoryStart else { throw StoredZipError.outOfBounds(offset: local) }
            guard bytes.le32(at: local) == Self.localSignature else { throw StoredZipError.badSignature(offset: local) }
            let localNameLength = Int(bytes.le16(at: local + 26))
            let dataStart = local + Self.localHeaderLength + localNameLength + Int(bytes.le16(at: local + 28))
            guard dataStart + size <= directoryStart else { throw StoredZipError.outOfBounds(offset: local) }
            let localName = bytes[local + Self.localHeaderLength ..< local + Self.localHeaderLength + localNameLength]
            guard localName.elementsEqual(nameBytes), bytes.le16(at: local + 8) == method else {
                throw StoredZipError.headerMismatch(name: name)
            }
            // Bit 3: the local CRC and sizes are zero and follow the data instead.
            if bytes.le16(at: local + 6) & 8 == 0 {
                guard bytes.le32(at: local + 14) == crc, Int(bytes.le32(at: local + 18)) == size,
                      Int(bytes.le32(at: local + 22)) == size else {
                    throw StoredZipError.headerMismatch(name: name)
                }
            }
            let range = dataStart..<dataStart + size
            let actual = Self.crc32(bytes[range])
            guard actual == crc else { throw StoredZipError.crcMismatch(name: name, expected: crc, actual: actual) }

            names.append(name)
            ranges[name] = range
            p = next
        }
        guard p == directoryEnd else { throw StoredZipError.badDirectory }
        self.names = names
        self.bytes = bytes
        self.ranges = ranges
    }

    /// The bytes of the entry with exactly this name, or nil if there is none.
    public func data(named name: String) -> Data? {
        ranges[name].map { Data(bytes[$0]) }
    }

    /// The end-of-central-directory record: the last one whose comment ends
    /// exactly at the end of the data.
    static func endRecord(in bytes: [UInt8]) throws -> Int {
        guard bytes.count >= endRecordLength else { throw StoredZipError.noEndRecord }
        let last = bytes.count - endRecordLength
        for p in stride(from: last, through: max(0, last - 0xFFFF), by: -1)
        where bytes.le32(at: p) == endSignature && p + endRecordLength + Int(bytes.le16(at: p + 20)) == bytes.count {
            return p
        }
        throw StoredZipError.noEndRecord
    }

    /// CRC-32 as ZIP uses it (reflected, polynomial 0xEDB88320).
    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        ~bytes.reduce(0xFFFF_FFFF as UInt32) { crc, byte in crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ crc >> 8 }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ c >> 1 : c >> 1 }
    }
}

public enum StoredZipError: Error, Equatable, Sendable {
    /// No end-of-central-directory record: not a ZIP archive, or cut short.
    case noEndRecord
    /// A record or an entry's bytes lie outside the space available to them:
    /// the archive was cut short or its offsets are corrupt.
    case outOfBounds(offset: Int)
    /// A header doesn't start with its signature.
    case badSignature(offset: Int)
    /// The central directory doesn't end where the end record says.
    case badDirectory
    /// An entry name is empty or not UTF-8.
    case badName(offset: Int)
    case duplicateName(String)
    /// Multi-disk, ZIP64 and encrypted archives.
    case unsupported(String)
    case compressed(name: String, method: UInt16)
    /// A stored entry whose compressed and uncompressed sizes differ.
    case sizeMismatch(name: String)
    /// An entry's local header disagrees with the central directory.
    case headerMismatch(name: String)
    case crcMismatch(name: String, expected: UInt32, actual: UInt32)
}
