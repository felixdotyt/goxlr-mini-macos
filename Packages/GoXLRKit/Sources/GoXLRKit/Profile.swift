// Our own profiles: the mixer and mic settings the helper applies, stored as
// JSON in ~/Library/Application Support/XLR/Profiles (PROMPT.md Phase 7).
// A profile may hold only some parts (mixer, mic, colours); applying it
// changes only those. Official `.goxlr` profiles are imported into this form
// (OfficialProfile).

import Foundation

public struct DeviceProfile: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var name: String
    /// Faders, volumes, routing, mute buttons and displays; nil when the
    /// profile leaves the mixer alone.
    public var mixer: MixerState?
    /// Mic type, gain and gate threshold; unset fields are left alone.
    public var mic: MicSettings
    /// Gate, compressor and bleep; nil in profiles saved before they existed.
    public var processing: MicProcessing?
    /// Colours; nil when the profile carries none.
    public var lighting: Lighting?

    public init(name: String, mixer: MixerState? = nil, mic: MicSettings = MicSettings(),
                processing: MicProcessing? = nil, lighting: Lighting? = nil) {
        formatVersion = Self.formatVersion
        self.name = name
        self.mixer = mixer
        self.mic = mic
        self.processing = processing
        self.lighting = lighting
    }

    /// What applying this profile changes.
    public var parts: [ProfilePart] {
        var parts = [ProfilePart]()
        if mixer != nil { parts.append(.mixer) }
        if mic != MicSettings() || processing.map({ !$0.payload.isEmpty }) == true { parts.append(.mic) }
        if lighting != nil { parts.append(.lighting) }
        return parts
    }
}

public enum ProfilePart: String, CaseIterable, Sendable {
    case mixer, mic, lighting

    public var title: String {
        switch self {
        case .mixer: return "Mixer"
        case .mic: return "Mic"
        case .lighting: return "Colours"
        }
    }
}

extension MicType: Codable {}

extension MicSettings: Codable {
    private enum CodingKeys: String, CodingKey { case type, gain, gateThreshold }

    /// Decoding goes through the clamping initialiser, so a hand-edited file
    /// can't carry values outside the tested ranges.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try container.decodeIfPresent(MicType.self, forKey: .type),
                  gain: try container.decodeIfPresent(Int.self, forKey: .gain),
                  gateThreshold: try container.decodeIfPresent(Int.self, forKey: .gateThreshold))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(gain, forKey: .gain)
        try container.encodeIfPresent(gateThreshold, forKey: .gateThreshold)
    }
}

public enum ProfileStoreError: Error, Equatable, CustomStringConvertible {
    case badName(String)
    case newerFormat(Int)

    public var description: String {
        switch self {
        case .badName(let name): return "\"\(name)\" can't be used as a profile name"
        case .newerFormat(let version): return "the profile is format \(version), newer than this app reads"
        }
    }
}

public struct ProfileStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static var standard: ProfileStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ProfileStore(directory: support.appendingPathComponent("XLR/Profiles", isDirectory: true))
    }

    /// Profile names, sorted. The file name is the profile's name (a copied file
    /// is its own profile); files that aren't profiles are skipped.
    public func names() -> [String] { all().map(\.name) }

    /// Every profile, sorted by name; files that aren't profiles are skipped.
    public func all() -> [DeviceProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .filter { file in (try? url(for: file.deletingPathExtension().lastPathComponent))?.standardizedFileURL == file.standardizedFileURL }
            .compactMap { try? load(url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Whether saving under this name would replace a file (the file system
    /// may ignore case, so this asks it rather than comparing names).
    public func exists(_ name: String) -> Bool {
        guard let url = try? url(for: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func load(_ name: String) throws -> DeviceProfile { try load(url: try url(for: name)) }

    public func save(_ profile: DeviceProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(profile).write(to: try url(for: profile.name), options: .atomic)
    }

    public func delete(_ name: String) throws { try FileManager.default.removeItem(at: try url(for: name)) }

    /// `base`, or `base 2` … `base 99`, whichever is free first.
    public func availableName(_ base: String) -> String? {
        ([base] + (2...99).map { "\(base) \($0)" }).first { (try? url(for: $0)) != nil && !exists($0) }
    }

    /// Saves the profiles whose names are free; returns the names saved.
    @discardableResult
    public func addMissing(_ profiles: [DeviceProfile]) throws -> [String] {
        var added = [String]()
        for profile in profiles where !exists(profile.name) {
            try save(profile)
            added.append(profile.name)
        }
        return added
    }

    /// Whether the store has never been written (no directory yet).
    public var isNew: Bool { !FileManager.default.fileExists(atPath: directory.path) }

    /// Reads one of our profiles from a file anywhere and saves it under the
    /// file's name (numbered if taken). Returns the name it was saved as.
    public func importProfile(from file: URL) throws -> String {
        var profile = try load(url: file)
        guard let name = availableName(file.deletingPathExtension().lastPathComponent) else {
            throw ProfileStoreError.badName(file.deletingPathExtension().lastPathComponent)
        }
        profile.name = name
        try save(profile)
        return name
    }

    /// The profile as a file's contents, for exporting.
    public func data(for name: String) throws -> Data { try Self.encode(try load(name)) }

    static func encode(_ profile: DeviceProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    private func load(url: URL) throws -> DeviceProfile {
        var profile = try JSONDecoder().decode(DeviceProfile.self, from: Data(contentsOf: url))
        guard profile.formatVersion <= DeviceProfile.formatVersion else { throw ProfileStoreError.newerFormat(profile.formatVersion) }
        profile.name = url.deletingPathExtension().lastPathComponent
        return profile
    }

    /// One file per name. Names that would leave the directory or hide the file are refused.
    private func url(for name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 200 bytes leaves room for ".json" in a 255-byte file name.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed.utf8.count <= 200 else { throw ProfileStoreError.badName(name) }
        return directory.appendingPathComponent(trimmed + ".json")
    }
}
