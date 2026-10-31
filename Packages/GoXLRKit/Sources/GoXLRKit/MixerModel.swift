// The host's model of the GoXLR's mixer and its host-side button behaviour.
//
// The device can't be read back (its mixer state has no read command), so the
// model holds what this host has set: a nil or missing value means "not set by
// us; the device keeps its own". Every change returns the commands that make
// the device match; nothing here talks to the device.
//
// Button behaviour follows goxlr-utility's for the Mini (daemon `device.rs`,
// read for behaviour only): a fader mute button mutes its channel to all or
// to one output (by removing it from that output's routing); holding it always
// mutes to all and flashes. The Mini doesn't move volumes on mute. The cough
// button works the same way for the mic, in hold or toggle mode. The bleep
// tone comes from the device; the host only lights the button.

import Foundation

public struct FaderDisplay: Codable, Hashable, Sendable {
    public var gradient: Bool
    public var meter: Bool

    public init(gradient: Bool, meter: Bool) {
        self.gradient = gradient
        self.meter = meter
    }
}

public struct CoughSettings: Codable, Equatable, Sendable {
    public var function: MuteFunction
    /// Toggle: press to mute, press again to unmute. Otherwise mute while held.
    public var toggle: Bool

    public init(function: MuteFunction = .all, toggle: Bool = false) {
        self.function = function
        self.toggle = toggle
    }
}

/// The mixer settings a profile carries; nil or missing = not set.
public struct MixerState: Codable, Equatable, Sendable {
    public var volumes: [Channel: UInt8] = [:]
    public var faders: [Fader: Channel] = [:]
    /// Base routing per input, before any mute-to-X. A missing input is unknown.
    public var routing: [RoutingInput: Set<RoutingOutput>] = [:]
    public var muteFunctions: [Fader: MuteFunction] = [:]
    public var cough = CoughSettings()
    public var faderDisplays: [Fader: FaderDisplay] = [:]
    /// How a button looks when it isn't active (the official app's "off style").
    public var offLight: ButtonLight = .dimmedColour1

    public init() {}

    public func muteFunction(_ fader: Fader) -> MuteFunction { muteFunctions[fader] ?? .all }

    private enum CodingKeys: String, CodingKey { case volumes, faders, routing, muteFunctions, cough, faderDisplays, offLight }

    /// Every field is optional on decode, so a saved state from an older
    /// version (or with a field added later) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumes = try c.decodeIfPresent([Channel: UInt8].self, forKey: .volumes) ?? [:]
        faders = try c.decodeIfPresent([Fader: Channel].self, forKey: .faders) ?? [:]
        routing = try c.decodeIfPresent([RoutingInput: Set<RoutingOutput>].self, forKey: .routing) ?? [:]
        muteFunctions = try c.decodeIfPresent([Fader: MuteFunction].self, forKey: .muteFunctions) ?? [:]
        cough = try c.decodeIfPresent(CoughSettings.self, forKey: .cough) ?? CoughSettings()
        faderDisplays = try c.decodeIfPresent([Fader: FaderDisplay].self, forKey: .faderDisplays) ?? [:]
        offLight = try c.decodeIfPresent(ButtonLight.self, forKey: .offLight) ?? .dimmedColour1
    }
}

/// Which settings this host has sent since the device last attached. The
/// device forgets its mixer at power-up, so a saved setting may not be on it.
public struct AppliedSettings: Equatable, Sendable {
    public var faders: Set<Fader> = []
    public var routing: Set<RoutingInput> = []
    public var volumes: Set<Channel> = []
    public var faderDisplays: Set<Fader> = []
}

public enum MuteState: Equatable, Sendable {
    case unmuted
    case mutedToX
    case mutedToAll(blink: Bool)

    public var isMuted: Bool { self != .unmuted }
}

public enum ButtonEvent: Equatable, Sendable {
    case down(Button)
    case held(Button)
    case up(Button, holdHandled: Bool)
}

/// Turns input-state snapshots into press, hold and release events. Holds need
/// `update` to be called again after `holdTime` while a button stays down.
public struct ButtonTracker: Sendable {
    public var holdTime: TimeInterval
    private var pressedAt: [Button: TimeInterval] = [:]
    private var holdHandled: Set<Button> = []

    public init(holdTime: TimeInterval = 0.5) { self.holdTime = holdTime }

    public mutating func update(pressed bits: UInt32, at now: TimeInterval) -> [ButtonEvent] {
        let pressed = Set(Button.allCases.filter { bits >> $0.rawValue & 1 != 0 })
        var events = [ButtonEvent]()
        for button in Button.allCases {
            let down = pressed.contains(button)
            if down, pressedAt[button] == nil {
                pressedAt[button] = now
                events.append(.down(button))
            } else if down, let start = pressedAt[button], !holdHandled.contains(button), now - start >= holdTime {
                holdHandled.insert(button)
                events.append(.held(button))
            } else if !down, pressedAt[button] != nil {
                events.append(.up(button, holdHandled: holdHandled.contains(button)))
                pressedAt[button] = nil
                holdHandled.remove(button)
            }
        }
        return events
    }

    /// Forget presses, e.g. when the device detaches.
    public mutating func reset() {
        pressedAt = [:]
        holdHandled = []
    }
}

public struct MixerModel: Sendable {
    /// The settings the user has made (shown, saved and restored). Button
    /// behaviour only relies on the parts in `applied`.
    public private(set) var state: MixerState
    public private(set) var applied = AppliedSettings()
    public var features: FirmwareFeatures
    public private(set) var faderMutes: [Fader: MuteState] = [:]
    public private(set) var cough: MuteState = .unmuted
    public private(set) var bleepDown = false
    /// Channels this host has muted with 0x809.
    public private(set) var mutedChannels: Set<Channel> = []

    public init(state: MixerState = MixerState(), features: FirmwareFeatures = .testedMini) {
        self.state = state
        self.features = features
    }

    public func muteState(_ fader: Fader) -> MuteState { faderMutes[fader] ?? .unmuted }

    // MARK: Settings

    public mutating func setVolume(_ channel: Channel, _ value: UInt8) -> [DeviceCommand] {
        state.volumes[channel] = value
        applied.volumes.insert(channel)
        return [.volume(channel, value)]
    }

    /// Moving a muted fader to another channel unmutes it first, so no channel
    /// stays muted without a lit button.
    public mutating func setFader(_ fader: Fader, _ channel: Channel) -> [DeviceCommand] {
        guard state.faders[fader] != channel || !applied.faders.contains(fader) else { return [] }
        var commands = muteState(fader).isMuted ? unmute(fader) : []
        state.faders[fader] = channel
        applied.faders.insert(fader)
        commands.append(.fader(fader, channel))
        return commands + [lights()]
    }

    /// Routing rows have bytes for Stream Mix 2 on Mix2 firmware, which this
    /// model doesn't track yet, so it won't write them there.
    public var canWriteRouting: Bool { !features.mix2 }

    public mutating func setRouting(_ input: RoutingInput, _ outputs: Set<RoutingOutput>) -> [DeviceCommand] {
        guard canWriteRouting else { return [] }
        state.routing[input] = outputs
        applied.routing.insert(input)
        return routingCommands(input)
    }

    public mutating func setMuteFunction(_ fader: Fader, _ function: MuteFunction) -> [DeviceCommand] {
        guard state.muteFunction(fader) != function else { return [] }
        let commands = muteState(fader).isMuted ? unmute(fader) : []
        state.muteFunctions[fader] = function
        return commands + [lights()]
    }

    public mutating func setCough(_ settings: CoughSettings) -> [DeviceCommand] {
        guard state.cough != settings else { return [] }
        let commands = cough.isMuted ? releaseCough() : []
        state.cough = settings
        return commands + [lights()]
    }

    public mutating func setFaderDisplay(_ fader: Fader, _ display: FaderDisplay) -> [DeviceCommand] {
        state.faderDisplays[fader] = display
        applied.faderDisplays.insert(fader)
        return [.faderDisplay(fader, gradient: display.gradient, meter: display.meter)]
    }

    public mutating func setOffLight(_ light: ButtonLight) -> [DeviceCommand] {
        state.offLight = light
        return [lights()]
    }

    /// Replaces every setting, e.g. from a profile: releases the current mutes
    /// first (they belong to the old assignments), then sends the new settings.
    public mutating func apply(_ newState: MixerState) -> [DeviceCommand] {
        let release = releaseAllMutes()
        state = newState
        return release + applyAll()
    }

    /// Sends everything set: faders, volumes, routing and displays. Unset
    /// settings are left alone. Lights are separate (`lights()`): only button
    /// handling owns them.
    public mutating func applyAll() -> [DeviceCommand] {
        var commands = applyAssignments()
        for channel in Channel.allCases {
            if let volume = state.volumes[channel] {
                commands.append(.volume(channel, volume))
                applied.volumes.insert(channel)
            }
        }
        for fader in Fader.allCases {
            if let display = state.faderDisplays[fader] {
                commands.append(.faderDisplay(fader, gradient: display.gradient, meter: display.meter))
                applied.faderDisplays.insert(fader)
            }
        }
        return commands
    }

    /// Sends the fader channels and routing, which the buttons need to know.
    public mutating func applyAssignments() -> [DeviceCommand] {
        var commands = [DeviceCommand]()
        for fader in Fader.allCases {
            if let channel = state.faders[fader] {
                commands.append(.fader(fader, channel))
                applied.faders.insert(fader)
            }
        }
        if canWriteRouting {
            for input in RoutingInput.allCases where state.routing[input] != nil {
                applied.routing.insert(input)
                commands += routingCommands(input)
            }
        }
        return commands
    }

    /// Undoes every mute this host made: unmutes its channels and puts back the
    /// routing a mute-to-X took away. For a re-attach without a power cut (the
    /// device keeps them), turning button handling off, and quitting.
    public mutating func releaseAllMutes() -> [DeviceCommand] {
        let toX = Set(Fader.allCases.filter { muteState($0) == .mutedToX }.compactMap { state.faders[$0] })
            .union(cough == .mutedToX ? [.mic] : [])
        faderMutes = [:]
        cough = .unmuted
        var commands = mutedChannels.sorted(by: { $0.rawValue < $1.rawValue }).map { DeviceCommand.mute($0, false) }
        mutedChannels = []
        for channel in toX.sorted(by: { $0.rawValue < $1.rawValue }) { commands += routingCommands(for: channel) }
        return commands
    }

    /// A new attach: the device lost its mixer with power (or kept it, if it
    /// wasn't power-cycled; release mutes first in that case), and any button
    /// held during the detach is gone.
    public mutating func deviceAttached() {
        faderMutes = [:]
        cough = .unmuted
        bleepDown = false
        mutedChannels = []
        applied = AppliedSettings()
    }

    // MARK: Buttons

    public mutating func handle(_ event: ButtonEvent) -> [DeviceCommand] {
        switch event {
        case .down(.cough): return pressCough()
        case .down(.bleep):
            bleepDown = true
            return [lights()]
        case .down: return []
        case .held(.cough): return holdCough()
        case .held(let button):
            guard let fader = button.fader else { return [] }
            return faderButton(fader, held: true)
        case .up(.cough, let holdHandled): return releaseCough(holdHandled: holdHandled)
        case .up(.bleep, _):
            bleepDown = false
            return [lights()]
        case .up(let button, let holdHandled):
            guard let fader = button.fader, !holdHandled else { return [] }
            return faderButton(fader, held: false)
        }
    }

    /// The window's mute button for a fader: the same as a short press.
    public mutating func toggleMute(_ fader: Fader) -> [DeviceCommand] { faderButton(fader, held: false) }

    /// A fader whose channel this host hasn't sent since the device attached
    /// does nothing: the device may control another channel with it.
    private mutating func faderButton(_ fader: Fader, held: Bool) -> [DeviceCommand] {
        guard state.faders[fader] != nil, applied.faders.contains(fader) else { return [] }
        let current = muteState(fader)
        if held {
            if case .mutedToAll = current { return [] }
            return muteToAll(fader, blink: true)
        }
        if current.isMuted { return unmute(fader) }
        if state.muteFunction(fader) == .all || !canMuteToX(state.faders[fader]) { return muteToAll(fader, blink: false) }
        faderMutes[fader] = .mutedToX
        return routingCommands(for: state.faders[fader]) + [lights()]
    }

    private mutating func muteToAll(_ fader: Fader, blink: Bool) -> [DeviceCommand] {
        let wasToX = muteState(fader) == .mutedToX
        faderMutes[fader] = .mutedToAll(blink: blink)
        var commands = [DeviceCommand]()
        if let channel = state.faders[fader] {
            commands += setChannelMuted(channel, true)
            if wasToX { commands += routingCommands(for: channel) }
        }
        return commands + [lights()]
    }

    private mutating func unmute(_ fader: Fader) -> [DeviceCommand] {
        let previous = muteState(fader)
        faderMutes[fader] = .unmuted
        guard let channel = state.faders[fader] else { return [lights()] }
        var commands = [DeviceCommand]()
        if case .mutedToAll = previous, !channelMutedToAll(channel) { commands += setChannelMuted(channel, false) }
        if previous == .mutedToX { commands += routingCommands(for: channel) }
        return commands + [lights()]
    }

    private mutating func pressCough() -> [DeviceCommand] {
        if state.cough.toggle { return [] }
        return muteCough(toAll: state.cough.function == .all || !canMuteToX(.mic), blink: false)
    }

    private mutating func holdCough() -> [DeviceCommand] {
        guard state.cough.toggle else { return [] }
        return muteCough(toAll: true, blink: true)
    }

    private mutating func releaseCough(holdHandled: Bool = false) -> [DeviceCommand] {
        if state.cough.toggle {
            if holdHandled { return [] }
            if !cough.isMuted { return muteCough(toAll: state.cough.function == .all || !canMuteToX(.mic), blink: false) }
        }
        guard cough.isMuted else { return [] }
        let previous = cough
        cough = .unmuted
        var commands = [DeviceCommand]()
        if case .mutedToAll = previous, !channelMutedToAll(.mic) { commands += setChannelMuted(.mic, false) }
        if previous == .mutedToX { commands += routingCommands(for: .mic) }
        return commands + [lights()]
    }

    private mutating func muteCough(toAll: Bool, blink: Bool) -> [DeviceCommand] {
        let wasToX = cough == .mutedToX
        if toAll {
            cough = .mutedToAll(blink: blink)
            return setChannelMuted(.mic, true) + (wasToX ? routingCommands(for: .mic) : []) + [lights()]
        }
        cough = .mutedToX
        return routingCommands(for: .mic) + [lights()]
    }

    // MARK: Device state

    /// Mute-to-X rewrites the input's routing rows, so it needs the base routing.
    private func canMuteToX(_ channel: Channel?) -> Bool {
        guard canWriteRouting, let input = channel.flatMap(Self.input) else { return false }
        return state.routing[input] != nil && applied.routing.contains(input)
    }

    /// Whether something other than the caller still mutes this channel to all.
    private func channelMutedToAll(_ channel: Channel) -> Bool {
        let byFader = Fader.allCases.contains { fader in
            guard state.faders[fader] == channel, case .mutedToAll = muteState(fader) else { return false }
            return true
        }
        if case .mutedToAll = cough, channel == .mic { return true }
        return byFader
    }

    private mutating func setChannelMuted(_ channel: Channel, _ muted: Bool) -> [DeviceCommand] {
        guard mutedChannels.contains(channel) != muted else { return [] }
        if muted { mutedChannels.insert(channel) } else { mutedChannels.remove(channel) }
        return [.mute(channel, muted)]
    }

    private static func input(_ channel: Channel) -> RoutingInput? {
        RoutingInput.allCases.first { $0.channel == channel }
    }

    private func routingCommands(for channel: Channel?) -> [DeviceCommand] {
        guard let input = channel.flatMap(Self.input) else { return [] }
        return routingCommands(input)
    }

    /// The input's rows: its base routing minus the outputs that a mute-to-X
    /// (fader or cough) currently removes.
    private func routingCommands(_ input: RoutingInput) -> [DeviceCommand] {
        guard canWriteRouting, var outputs = state.routing[input] else { return [] }
        for fader in Fader.allCases where state.faders[fader] == input.channel && muteState(fader) == .mutedToX {
            outputs.subtract(state.muteFunction(fader).outputs ?? [])
        }
        if input == .mic, cough == .mutedToX { outputs.subtract(state.cough.function.outputs ?? []) }
        return Routing.rows(for: input, to: outputs, features: features)
    }

    /// 0x808: muted buttons lit (flashing after a hold), others in the off style.
    public func lights() -> DeviceCommand {
        var bytes = [UInt8](repeating: 0, count: 24)
        func light(_ state: MuteState) -> ButtonLight {
            switch state {
            case .unmuted: return self.state.offLight
            case .mutedToX, .mutedToAll(blink: false): return .colour1
            case .mutedToAll(blink: true): return .flashing
            }
        }
        for fader in Fader.allCases { bytes[Int(fader.muteButton.rawValue)] = light(muteState(fader)).rawValue }
        bytes[Int(Button.cough.rawValue)] = light(cough).rawValue
        bytes[Int(Button.bleep.rawValue)] = (bleepDown ? ButtonLight.colour1 : state.offLight).rawValue
        return .buttonLights(bytes)
    }
}
