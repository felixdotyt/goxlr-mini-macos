// Reads an official TC-Helicon `.goxlr` profile into the facts that matter on a
// GoXLR Mini (docs/protocol/profile-format.md, "Value encodings"). It only
// decodes: turning these facts into device commands happens elsewhere.
//
// Every attribute is optional, because the samples don't all carry the same
// set. Values whose meaning isn't established stay raw, and their typed views
// return nil. Skipped, because they are full-GoXLR-only or host UI state:
// effects and encoders, the sampler, scribbles and their PNGs, fxClear,
// selectedContext, browserPreviewTree, AppTree and the root `loudness`.

import Foundation

public struct OfficialProfile: Equatable, Sendable {
    /// `ValueTreeRoot` `version` (1 in every sample).
    public var version: Int?
    /// `ValueTreeRoot` `device`: the USB product ID the profile was made for
    /// (0x8FE0, the full GoXLR, in every sample).
    public var devicePID: Int?
    /// `mixerTree` `<channel>Level`, raw. 0–255 in the samples, as for 0x806.
    public var levels: [Channel: Int] = [:]
    /// The outputs each input is routed to, for inputs whose five switches
    /// are all present with a known value (0 off, 8192 on).
    public var routing: [RoutingInput: Set<RoutingOutput>] = [:]
    /// Every `<input>To<output>` switch found, raw.
    public var routingValues: [RoutingInput: [RoutingOutput: Int]] = [:]
    /// `mixerTree` `MiniLockFadersToLabels`, raw; its meaning isn't established.
    public var miniLockFadersToLabels: Int?
    /// `FaderMeter0`…`3`, keyed by fader A–D.
    public var faders: [Fader: FaderSettings] = [:]
    /// `mute1`…`4`, keyed by fader A–D.
    public var muteButtons: [Fader: MuteButton] = [:]
    /// `muteChat`.
    public var cough: CoughButton?
    /// `swear`.
    public var bleep: ProfileButton?
    /// `logoX`.
    public var logo: ProfileButton?
    /// `globalColour` (no state attribute).
    public var globalColour: ProfileButton?
    /// Attributes the importer reads that weren't in the expected form. Values
    /// kept raw elsewhere (strings, colours) never appear here.
    public var undecoded: [UndecodedValue] = []

    public static func load(contentsOf url: URL) throws -> OfficialProfile {
        try OfficialProfile(zipData: Data(contentsOf: url))
    }

    public init(zipData: Data) throws {
        let zip: StoredZip
        do {
            zip = try StoredZip(data: zipData)
        } catch let error as StoredZipError {
            throw OfficialProfileError.damaged(error)
        }
        guard let xml = zip.data(named: "profile.xml") else { throw OfficialProfileError.missingProfileXML }
        try self.init(xml: xml)
    }

    init(xml: Data) throws {
        let tree = try ValueTreeReader.read(xml)
        guard tree.root == "ValueTreeRoot" else { throw OfficialProfileError.notValueTreeRoot(found: tree.root) }
        var reader = AttributeReader()
        version = reader.int(tree.rootAttributes, "version", in: "ValueTreeRoot")
        devicePID = reader.int(tree.rootAttributes, "device", in: "ValueTreeRoot")

        if let mixer = tree.children["mixerTree"] {
            for (attribute, channel) in Self.levelAttributes {
                levels[channel] = reader.int(mixer, attribute, in: "mixerTree")
            }
            for input in RoutingInput.allCases {
                var values = [RoutingOutput: Int]()
                for (suffix, output) in Self.routingOutputs {
                    values[output] = reader.int(mixer, input.rawValue + "To" + suffix, in: "mixerTree")
                }
                if !values.isEmpty { routingValues[input] = values }
                if values.count == Self.routingOutputs.count, values.values.allSatisfy({ $0 == 0 || $0 == Self.routedOn }) {
                    routing[input] = Set(values.filter { $0.value == Self.routedOn }.keys)
                }
            }
            miniLockFadersToLabels = reader.int(mixer, "MiniLockFadersToLabels", in: "mixerTree")
        }

        for fader in Fader.allCases {
            let meter = "FaderMeter\(fader.rawValue)"
            if let a = tree.children[meter] {
                faders[fader] = FaderSettings(listIndex: reader.int(a, meter + "listIndex", in: meter),
                                              display: a[meter + "Display"],
                                              colour0: a[meter + "colour0"].map(ProfileColour.init(raw:)),
                                              colour1: a[meter + "colour1"].map(ProfileColour.init(raw:)),
                                              offStyle: a[meter + "offStyle"])
            }
            let mute = "mute\(fader.rawValue + 1)"
            if let a = tree.children[mute] {
                muteButtons[fader] = MuteButton(button: reader.button(a, mute),
                                                function: a[mute + "Function"],
                                                blink: reader.int(a, mute + "blink", in: mute),
                                                prevLevel: reader.int(a, mute + "prevLevel", in: mute))
            }
        }

        if let a = tree.children["muteChat"] {
            cough = CoughButton(button: reader.button(a, "muteChat"),
                                toggleSetting: reader.int(a, "coughButtonToggleSetting", in: "muteChat"),
                                muteSourceSelection: reader.int(a, "coughButtonMuteSourceSelection", in: "muteChat"),
                                isOn: reader.int(a, "coughButtonIsOn", in: "muteChat"),
                                blink: reader.int(a, "blink", in: "muteChat"))
        }
        bleep = tree.children["swear"].map { reader.button($0, "swear") }
        logo = tree.children["logoX"].map { reader.button($0, "logoX") }
        globalColour = tree.children["globalColour"].map { reader.button($0, "globalColour") }
        undecoded = reader.undecoded
    }

    // MARK: Encodings (profile-format.md "Value encodings")

    /// The routing switch value for "routed" (0x2000). 0 is "not routed".
    static let routedOn = 8192

    static let levelAttributes: [(String, Channel)] = [
        ("micLevel", .mic), ("lineInLevel", .lineIn), ("consoleLevel", .console), ("systemLevel", .system),
        ("gameLevel", .game), ("chatLevel", .chat), ("sampleLevel", .sample), ("musicLevel", .music),
        ("headphoneLevel", .headphones), ("mic2headphoneSubLevel", .micMonitor), ("lineOutLevel", .lineOut),
    ]

    static let routingOutputs: [(String, RoutingOutput)] = [
        ("Stream", .broadcast), ("Chat", .chatMic), ("HP", .headphones), ("Sampler", .sampler), ("LineOut", .lineOut),
    ]

    /// `listIndex` is a position in the app's fader channel list. 0, 1, 2 and 6
    /// are derived from the samples; the rest from the order the app builds
    /// the list in.
    static let listIndexChannels: [Channel] = [
        .mic, .chat, .music, .game, .console, .lineIn, .system, .sample, .headphones, .lineOut,
    ]

    public static func channel(listIndex: Int) -> Channel? {
        listIndexChannels.indices.contains(listIndex) ? listIndexChannels[listIndex] : nil
    }

    /// `mute<n>Function` strings: "All" is in every sample; the others are the
    /// labels the app writes for its five mute functions.
    static let muteFunctions: [String: MuteFunction] = [
        "All": .all, "Mute All": .all, "Mute to Stream": .toStream, "Mute to Voice Chat": .toChat,
        "Mute to Phones": .toPhones, "Mute to Line Out": .toLineOut,
    ]

    public static func muteFunction(_ raw: String) -> MuteFunction? { muteFunctions[raw] }
}

public enum OfficialProfileError: Error, Equatable, Sendable {
    /// The container fails the ZIP checks (e.g. a text-mode re-encoded file).
    case damaged(StoredZipError)
    case missingProfileXML
    /// `profile.xml` isn't well-formed XML, or declares entities.
    case xmlParse(line: Int, column: Int, message: String)
    /// The root element isn't `ValueTreeRoot`; nil for a document without one.
    case notValueTreeRoot(found: String?)
}

/// An attribute value the importer expected in another form, kept raw.
public struct UndecodedValue: Equatable, Sendable {
    public var element: String
    public var attribute: String
    public var value: String
}

/// A colour as stored: eight hex digits, AARRGGBB, in either case.
public struct ProfileColour: Equatable, Hashable, Sendable {
    public var raw: String

    public init(raw: String) { self.raw = raw }

    /// Nil unless `raw` is exactly eight hex digits.
    public var argb: UInt32? {
        let hexDigits = raw.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
        return raw.utf8.count == 8 && hexDigits ? UInt32(raw, radix: 16) : nil
    }

    /// The alpha byte; its effect on the device isn't established.
    public var alpha: UInt8? { argb.map { UInt8($0 >> 24) } }

    public var rgb: RGB? {
        argb.map { RGB(red: UInt8($0 >> 16 & 0xFF), green: UInt8($0 >> 8 & 0xFF), blue: UInt8($0 & 0xFF)) }
    }
}

/// `<button>offStyle`: how an element looks when off.
public enum OffStyle: String, CaseIterable, Sendable {
    case dimmed = "DIMMED", colour2 = "COLOUR2", dimmedColour2 = "DIMMEDCOLOUR2"
}

/// `FaderMeter<n>Display`.
public enum FaderDisplayStyle: String, CaseIterable, Sendable {
    case twoColour = "TWO COLOR", gradient = "GRADIENT", meter = "METER", gradientMeter = "GRADIENT_METER"
}

/// The state, colours and off style every lit element has.
public struct ProfileButton: Equatable, Sendable {
    /// `<element>state`, raw (0 in every sample).
    public var state: Int?
    public var colour0: ProfileColour?
    public var colour1: ProfileColour?
    /// `<element>offStyle`, raw.
    public var offStyle: String?

    public var knownOffStyle: OffStyle? { offStyle.flatMap(OffStyle.init(rawValue:)) }
}

public struct FaderSettings: Equatable, Sendable {
    /// `FaderMeter<n>listIndex`, raw.
    public var listIndex: Int?
    /// `FaderMeter<n>Display`, raw.
    public var display: String?
    public var colour0: ProfileColour?
    public var colour1: ProfileColour?
    /// `FaderMeter<n>offStyle`, raw.
    public var offStyle: String?

    public var channel: Channel? { listIndex.flatMap(OfficialProfile.channel(listIndex:)) }
    public var knownDisplay: FaderDisplayStyle? { display.flatMap(FaderDisplayStyle.init(rawValue:)) }
    public var knownOffStyle: OffStyle? { offStyle.flatMap(OffStyle.init(rawValue:)) }
}

public struct MuteButton: Equatable, Sendable {
    public var button: ProfileButton
    /// `mute<n>Function`, raw.
    public var function: String?
    /// `mute<n>blink`, raw.
    public var blink: Int?
    /// `mute<n>prevLevel`: presumably the level to restore on unmute (inferred), raw.
    public var prevLevel: Int?

    /// Nil for a string the format notes don't list.
    public var muteFunction: MuteFunction? { function.flatMap(OfficialProfile.muteFunction) }
}

/// `muteChat`. The behaviour attributes are raw: only 0 is in the samples, so
/// their encodings aren't established.
public struct CoughButton: Equatable, Sendable {
    public var button: ProfileButton
    /// `coughButtonToggleSetting`: hold or toggle.
    public var toggleSetting: Int?
    /// `coughButtonMuteSourceSelection`: which outputs cough mutes.
    public var muteSourceSelection: Int?
    /// `coughButtonIsOn`.
    public var isOn: Int?
    /// `blink`, unprefixed on this element.
    public var blink: Int?
}

/// Reads typed attribute values and records the ones in an unexpected form.
private struct AttributeReader {
    var undecoded: [UndecodedValue] = []

    mutating func int(_ attributes: [String: String], _ name: String, in element: String) -> Int? {
        guard let raw = attributes[name] else { return nil }
        if let value = Int(raw) { return value }
        undecoded.append(UndecodedValue(element: element, attribute: name, value: raw))
        return nil
    }

    mutating func button(_ attributes: [String: String], _ element: String) -> ProfileButton {
        ProfileButton(state: int(attributes, element + "state", in: element),
                      colour0: attributes[element + "colour0"].map(ProfileColour.init(raw:)),
                      colour1: attributes[element + "colour1"].map(ProfileColour.init(raw:)),
                      offStyle: attributes[element + "offStyle"])
    }
}

/// The root element of `profile.xml` and its direct children (the first of
/// each name). Deeper elements are skipped.
private final class ValueTreeReader: NSObject, XMLParserDelegate {
    var root: String?
    var rootAttributes = [String: String]()
    var children = [String: [String: String]]()
    private var depth = 0
    private var refused = false

    static func read(_ xml: Data) throws -> ValueTreeReader {
        let reader = ValueTreeReader()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.refused else {
            let message = reader.refused ? "entity declarations are not allowed"
                : parser.parserError?.localizedDescription ?? "unknown error"
            throw OfficialProfileError.xmlParse(line: parser.lineNumber, column: parser.columnNumber, message: message)
        }
        return reader
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth == 1 {
            root = elementName
            rootAttributes = attributes
        } else if depth == 2, children[elementName] == nil {
            children[elementName] = attributes
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
    }

    // JUCE never writes a DTD; refuse entity declarations rather than expand them.
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        refuse(parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        refuse(parser)
    }

    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?, notationName: String?) {
        refuse(parser)
    }

    private func refuse(_ parser: XMLParser) {
        refused = true
        parser.abortParsing()
    }
}
