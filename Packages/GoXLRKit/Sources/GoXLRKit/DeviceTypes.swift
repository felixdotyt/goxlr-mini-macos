// The GoXLR's channels, faders, routing matrix and buttons, numbered as the
// device numbers them (commands.md; Mini confirmations in LEDGER L-119–L-129).

import Foundation

/// 0x806/0x809 index and 0x805 payload (commands.md "Channel, fader and encoder numbers").
public enum Channel: UInt32, CaseIterable, Codable, Sendable {
    case mic = 0, lineIn, console, system, game, chat, sample, music, headphones, micMonitor, lineOut

    public var title: String {
        switch self {
        case .mic: return "Mic"
        case .lineIn: return "Line In"
        case .console: return "Console"
        case .system: return "System"
        case .game: return "Game"
        case .chat: return "Chat"
        case .sample: return "Sample"
        case .music: return "Music"
        case .headphones: return "Headphones"
        case .micMonitor: return "Mic Monitor"
        case .lineOut: return "Line Out"
        }
    }

    /// Channels a fader can control (inputs; GU's fader channel list).
    public static let faderChannels: [Channel] = [.mic, .lineIn, .console, .system, .game, .chat, .sample, .music]
}

public enum Fader: UInt32, CaseIterable, Codable, Sendable {
    case a = 0, b, c, d

    public var title: String { ["A", "B", "C", "D"][Int(rawValue)] }
    /// The input-state bit of this fader's mute button (L-119).
    public var muteButton: Button { [.fader1Mute, .fader2Mute, .fader3Mute, .fader4Mute][Int(rawValue)] }
}

/// A routing-matrix input: one 0x804 row per side (commands.md "Routing").
public enum RoutingInput: String, CaseIterable, Codable, Sendable {
    case mic, lineIn, console, system, game, chat, music, sample

    public var title: String { channel.title }

    public var channel: Channel {
        switch self {
        case .mic: return .mic
        case .lineIn: return .lineIn
        case .console: return .console
        case .system: return .system
        case .game: return .game
        case .chat: return .chat
        case .music: return .music
        case .sample: return .sample
        }
    }

    /// 0x804 indices for the left and right rows.
    public var rows: (left: UInt32, right: UInt32) {
        let left: UInt32
        switch self {
        case .mic: left = 2
        case .lineIn: left = 4
        case .console: left = 6
        case .system: left = 8
        case .game: left = 10
        case .chat: left = 12
        case .music: left = 14
        case .sample: left = 16
        }
        return (left, left + 1)
    }
}

/// A routing-matrix output: byte positions in a row (22-byte rows without Mix2).
public enum RoutingOutput: String, CaseIterable, Codable, Sendable {
    case headphones, broadcast, chatMic, sampler, lineOut

    public var title: String {
        switch self {
        case .headphones: return "Headphones"
        case .broadcast: return "Stream Mix"
        case .chatMic: return "Chat Mic"
        case .sampler: return "Sampler"
        case .lineOut: return "Line Out"
        }
    }

    /// Byte offsets of this output's left and right u16 high bytes.
    public var bytes: (left: Int, right: Int) {
        switch self {
        case .headphones: return (1, 3)
        case .broadcast: return (5, 7)
        case .chatMic: return (9, 11)
        case .sampler: return (13, 15)
        case .lineOut: return (17, 19)
        }
    }
}

/// Buttons by input-state bit (commands.md "Input state bits"). The Mini has these six.
public enum Button: UInt32, CaseIterable, Codable, Sendable {
    case fader1Mute = 4, fader2Mute = 9, fader3Mute = 14, fader4Mute = 19, bleep = 22, cough = 23

    public var title: String {
        switch self {
        case .fader1Mute: return "Mute A"
        case .fader2Mute: return "Mute B"
        case .fader3Mute: return "Mute C"
        case .fader4Mute: return "Mute D"
        case .bleep: return "Bleep"
        case .cough: return "Cough"
        }
    }

    public var fader: Fader? { Fader.allCases.first { $0.muteButton == self } }
}

/// 0x808 values, one per button bit (commands.md).
public enum ButtonLight: UInt8, CaseIterable, Codable, Sendable {
    case colour2 = 0, colour1 = 1, dimmedColour1 = 2, flashing = 3, dimmedColour2 = 4
}

/// What a mute button silences (GU MuteFunction; the official profile's `Function`).
public enum MuteFunction: String, CaseIterable, Codable, Sendable {
    case all, toStream, toChat, toPhones, toLineOut

    public var title: String {
        switch self {
        case .all: return "Mute to all"
        case .toStream: return "Mute to stream"
        case .toChat: return "Mute to voice chat"
        case .toPhones: return "Mute to headphones"
        case .toLineOut: return "Mute to line out"
        }
    }

    /// The outputs a mute-to-X removes the channel from; nil for mute to all.
    public var outputs: [RoutingOutput]? {
        switch self {
        case .all: return nil
        case .toStream: return [.broadcast]
        case .toChat: return [.chatMic]
        case .toPhones: return [.headphones]
        case .toLineOut: return [.lineOut]
        }
    }
}

/// An RGB colour; the colour map stores it as B G R A (commands.md 0x803).
public struct RGB: Equatable, Hashable, Codable, Sendable {
    public var red, green, blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "RRGGBB", with or without a leading #.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    public var hex: String { String(format: "%02X%02X%02X", red, green, blue) }
}
