// The helper's connection to the GoXLR and everything it applies: the mic
// settings, the mixer model, host-side buttons and profiles. One serial queue
// sends every command (the device model is a single writer, PROMPT.md Phase 5).

import AppKit
import Foundation
import GoXLRKit
import os
import UniformTypeIdentifiers

/// The connection to the driver (or the simulator), kept across driver restarts
/// and device re-attaches. Driver calls run on `queue`, never on the main thread.
final class DriverLink {
    enum Change {
        case ready(DriverInfo?)
        case input(InputState)
        case detached
    }

    let queue = DispatchQueue(label: "yt.felix.xlr.helper.driver")
    let simulated: Bool
    private var monitor: DriverMonitor?
    private var device: XLRDevice?
    /// Whether this connection's ready was passed on: the driver reports ready
    /// on subscribe and again when its start finishes (L-131).
    private var announced = false

    init(simulated: Bool) { self.simulated = simulated }

    /// `handler` runs on `queue`.
    func start(_ handler: @escaping (Change) -> Void) {
        if simulated {
            queue.async { [self] in
                let simulator = Simulator()
                device = simulator
                announced = false
                try? simulator.subscribe(queue: queue) { [weak self] event in self?.received(event, handler) }
            }
            return
        }
        let monitor = DriverMonitor(queue: queue) { [weak self] change in
            guard let self else { return }
            switch change {
            case .connected(let client):
                device = client
                announced = false
            case .event(let event): received(event, handler)
            case .failed(let error): log.error("XLRHelper: driver connection failed: \(error.description, privacy: .public)")
            }
        }
        self.monitor = monitor
        monitor.start()
    }

    private func received(_ event: DriverEvent, _ handler: (Change) -> Void) {
        switch event {
        case .driverState(_, .ready?, _):
            guard !announced, let device else { return }
            announced = true
            handler(.ready(try? device.info()))
        case .inputState(_, let state): handler(.input(state))
        case .disconnected:
            device = nil
            announced = false
            handler(.detached)
        case .driverState: break
        }
    }

    /// Runs `body` on `queue` with the current connection, nil when the driver isn't there.
    func withDevice(_ body: @escaping (XLRDevice?) -> Void) {
        queue.async { [self] in body(device) }
    }
}

/// Values that change many times a second, kept apart so only the views that
/// show them redraw.
@MainActor
final class LiveLevels: ObservableObject {
    /// Fader positions A–D (0–255), from input state.
    @Published var faders: [UInt8] = []
    /// The mic meter (0x80C) in dBFS while a view shows it; nil when not polled.
    @Published var mic: Double?
}

@MainActor
final class DeviceSession: ObservableObject {
    enum Key {
        static let micType = "micType", micGain = "micGain", micGate = "micGateThreshold"
        static let mixer = "mixerState", buttonHandling = "buttonHandling", restoreMixer = "restoreMixerOnAttach"
        static let profile = "activeProfile", processing = "micProcessing"
        static let lighting = "lighting", animation = "animation"
    }

    @Published private(set) var mic: MicSettings
    /// Gate, compressor and bleep; only what the user has set is ever sent.
    @Published private(set) var processing: MicProcessing
    /// Colours, edited here and sent only on request: a map replaces the
    /// GoXLR's stored colours until its next power cycle.
    @Published var lighting: Lighting {
        didSet { if let data = try? JSONEncoder().encode(lighting) { UserDefaults.standard.set(data, forKey: Key.lighting) } }
    }
    @Published var animation: Animation {
        didSet { if let data = try? JSONEncoder().encode(animation) { UserDefaults.standard.set(data, forKey: Key.animation) } }
    }
    @Published private(set) var mixer: MixerModel
    private var mixerSavePending = false
    /// Counts attaches, so a delayed send can tell it's still the same one.
    private var attachment = 0
    @Published private(set) var info: DriverInfo?
    @Published private(set) var connected = false
    let live = LiveLevels()
    @Published private(set) var profileNames: [String] = []
    /// What each profile holds, by name.
    @Published private(set) var profileParts: [String: [ProfilePart]] = [:]
    @Published private(set) var activeProfile: String?
    @Published var status = ""
    /// Host-side buttons (mutes, cough, bleep light). Off until the user turns it
    /// on. On: the faders and routing set here are sent (the buttons act on
    /// them) and the lights follow the buttons. Off: this app's mutes are
    /// released and the lights go back to how the GoXLR showed them (L-121).
    @Published var buttonHandling: Bool {
        didSet {
            guard buttonHandling != oldValue else { return }
            UserDefaults.standard.set(buttonHandling, forKey: Key.buttonHandling)
            tracker.reset()
            if buttonHandling {
                send(mixer.applyAssignments() + [mixer.lights()], "button handling on")
            } else {
                send(mixer.releaseAllMutes() + [Self.lightsAsFound], "button handling off", lights: true)
            }
        }
    }

    /// 0x808 all zero: the state the Mini showed with no host (L-121).
    static let lightsAsFound = DeviceCommand.buttonLights([UInt8](repeating: 0, count: 24))
    /// Send the saved mixer (faders, volumes, routing, displays) at every attach.
    @Published var restoreMixerOnAttach: Bool {
        didSet { UserDefaults.standard.set(restoreMixerOnAttach, forKey: Key.restoreMixer) }
    }

    let store = ProfileStore.standard
    private let link: DriverLink
    private var tracker = ButtonTracker()
    private var lastButtons: UInt32 = 0
    private var meter: DispatchSourceTimer?
    private var meterViews = 0

    init(simulated: Bool) {
        link = DriverLink(simulated: simulated)
        let defaults = UserDefaults.standard
        mic = Self.savedMic
        processing = defaults.data(forKey: Key.processing).flatMap { try? JSONDecoder().decode(MicProcessing.self, from: $0) }
            ?? MicProcessing()
        // Unset until the user picks colours: the GoXLR's own can't be read.
        lighting = defaults.data(forKey: Key.lighting).flatMap { try? JSONDecoder().decode(Lighting.self, from: $0) }
            ?? Lighting()
        animation = defaults.data(forKey: Key.animation).flatMap { try? JSONDecoder().decode(Animation.self, from: $0) }
            ?? Animation()
        var state = MixerState()
        if let data = defaults.data(forKey: Key.mixer) {
            do {
                state = try JSONDecoder().decode(MixerState.self, from: data)
            } catch {
                // Keep the unreadable copy rather than overwrite it with the next save.
                defaults.set(data, forKey: Key.mixer + ".unreadable")
                log.error("XLRHelper: saved mixer unreadable (\(String(describing: error), privacy: .public)); kept a copy")
            }
        }
        mixer = MixerModel(state: state)
        buttonHandling = defaults.bool(forKey: Key.buttonHandling)
        restoreMixerOnAttach = defaults.bool(forKey: Key.restoreMixer)
        activeProfile = defaults.string(forKey: Key.profile)
        // First launch on this Mac: start with the default profiles.
        if store.isNew {
            do { try store.addMissing(DeviceProfile.defaults) } catch {
                log.error("XLRHelper: couldn't add the default profiles: \(String(describing: error), privacy: .public)")
            }
        }
        refreshProfiles()
    }

    var simulated: Bool { link.simulated }

    /// Read at each attach, so values written with `defaults write` are used.
    nonisolated static var savedMic: MicSettings {
        let defaults = UserDefaults.standard
        return MicSettings(type: defaults.string(forKey: Key.micType).flatMap(MicType.init(rawValue:)),
                           gain: defaults.object(forKey: Key.micGain) as? Int,
                           gateThreshold: defaults.object(forKey: Key.micGate) as? Int)
    }

    nonisolated static func describe(_ settings: MicSettings) -> String {
        "mic type \(settings.type?.rawValue ?? "not set"), gain \(settings.gain.map { "\($0) dB" } ?? "not set"), "
            + "gate \(settings.gateThreshold.map { "\($0) dB" } ?? "not set")"
    }

    func start() {
        link.start { [weak self] change in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(change) } }
        }
    }

    private func handle(_ change: DriverLink.Change) {
        switch change {
        case .ready(let info):
            connected = true
            self.info = info
            if let info, let model = info.model, model != .unknown {
                mixer.features = FirmwareFeatures(model: model, firmware: info.firmware)
            }
            // A re-attach without a power cut (driver restart, USB reset) keeps the
            // device's mutes, so release this app's before forgetting them.
            let release = mixer.releaseAllMutes()
            mixer.deviceAttached()
            tracker.reset()
            lastButtons = 0
            attachment += 1
            attached(release: release)
        case .input(let state):
            if live.faders != state.faders {
                live.faders = state.faders
                if mixer.faderReport(state.faders) { persistMixerSoon() }
            }
            buttons(state.buttons)
        case .detached:
            connected = false
            info = nil
            live.faders = []
        }
    }

    /// The Mini forgets everything at power-up (L-122, L-123, L-130).
    private func attached(release: [DeviceCommand]) {
        let mic = Self.savedMic
        self.mic = mic
        var commands = release
        if let payload = MicSetup.payloadOnAttach(mic) { commands.append(.micParameters(payload)) }
        if !processing.payload.isEmpty { commands.append(.micParameters(processing.payload)) }
        if restoreMixerOnAttach {
            commands += mixer.applyAll()
        } else if buttonHandling {
            // The faders' last volumes too: the Mini holds them at 0 until each
            // fader moves (L-142), so the Mac would be silent until then.
            commands += mixer.applyAssignments() + mixer.applyFaderVolumes()
        }
        if restoreMixerOnAttach || buttonHandling { resendFaderVolumes() }
        if buttonHandling { commands.append(mixer.lights()) }
        var what = "driver ready; \(Self.describe(mic))"
        if restoreMixerOnAttach { what += "; mixer restored" }
        if commands.isEmpty {
            log.notice("XLRHelper: \(what, privacy: .public): nothing to send")
            return
        }
        send(commands, what)
    }

    /// After a power-up the Mini sets the fader channels' volumes from the
    /// faders (0 until each moves) 2–3.5 s after it attaches, over what was sent
    /// at attach; sent 5 s after attach, they stayed (L-143).
    private func resendFaderVolumes() {
        let attachment = attachment
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.connected, self.attachment == attachment,
                      self.restoreMixerOnAttach || self.buttonHandling else { return }
                self.send(self.mixer.applyFaderVolumes(), "fader volumes again after attach")
            }
        }
    }

    // MARK: Buttons

    private func buttons(_ bits: UInt32) {
        guard buttonHandling else { return }
        lastButtons = bits
        let events = tracker.update(pressed: bits, at: ProcessInfo.processInfo.systemUptime)
        for event in events {
            send(mixer.handle(event), "\(event)")
            if case .down = event { scheduleHoldCheck() }
        }
    }

    /// Holds need a check after the hold time even if nothing else changes.
    private func scheduleHoldCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + tracker.holdTime + 0.02) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.buttonHandling else { return }
                self.buttons(self.lastButtons)
            }
        }
    }

    // MARK: Mixer

    func setVolume(_ channel: Channel, _ value: UInt8) { change(mixer.setVolume(channel, value), "\(channel.title) volume \(value)") }
    func setFader(_ fader: Fader, _ channel: Channel) { change(mixer.setFader(fader, channel), "fader \(fader.title) = \(channel.title)") }
    func toggleMute(_ fader: Fader) { change(mixer.toggleMute(fader), "fader \(fader.title) mute") }
    func setMuteFunction(_ fader: Fader, _ function: MuteFunction) {
        change(mixer.setMuteFunction(fader, function), "fader \(fader.title): \(function.title)")
    }
    func setCough(_ settings: CoughSettings) { change(mixer.setCough(settings), "cough: \(settings.function.title)") }
    func setFaderDisplay(_ fader: Fader, _ display: FaderDisplay) {
        change(mixer.setFaderDisplay(fader, display), "fader \(fader.title) display")
    }
    func setOffLight(_ light: ButtonLight) { change(mixer.setOffLight(light), "off style") }

    /// The first change to an input whose routing this app hasn't set writes its
    /// whole row, so it asks first (a click once took the mic off the stream).
    func setRouting(_ input: RoutingInput, _ output: RoutingOutput, _ on: Bool) {
        var outputs = mixer.state.routing[input] ?? []
        if on { outputs.insert(output) } else { outputs.remove(output) }
        if mixer.state.routing[input] == nil, !confirmFirstRouting(input, outputs) {
            objectWillChange.send()  // puts the clicked checkbox back
            return
        }
        change(mixer.setRouting(input, outputs), "routing \(input.title)")
    }

    private func confirmFirstRouting(_ input: RoutingInput, _ outputs: Set<RoutingOutput>) -> Bool {
        let on = RoutingOutput.allCases.filter { outputs.contains($0) }.map(\.title)
        let off = RoutingOutput.allCases.filter { !outputs.contains($0) }.map(\.title)
        let alert = NSAlert()
        alert.messageText = "Replace \(input.title)'s routing?"
        alert.informativeText = "The GoXLR can't report where \(input.title) goes now. This sets all of it: "
            + (on.isEmpty ? "" : "on for \(on.joined(separator: ", ")); ")
            + "off for \(off.joined(separator: ", ")). Tick other outputs afterwards to add them."
        alert.addButton(withTitle: "Set Routing")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func change(_ commands: [DeviceCommand], _ what: String) {
        persistMixer()
        send(commands, what)
    }

    /// Fader moves report many times a second; save at most once a second.
    private func persistMixerSoon() {
        guard !mixerSavePending else { return }
        mixerSavePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.mixerSavePending = false
                self?.persistMixer()
            }
        }
    }

    private func persistMixer() {
        if let data = try? JSONEncoder().encode(mixer.state) { UserDefaults.standard.set(data, forKey: Key.mixer) }
    }

    // MARK: Mic

    /// A condenser needs the user's confirmation first; the saved gain moves to
    /// the new type's gain key. False if the user cancelled.
    @discardableResult
    func selectMicType(_ type: MicType) -> Bool {
        if type.phantomPower && !confirmPhantom() {
            log.notice("XLRHelper: phantom power: the user cancelled")
            status = "Phantom power: cancelled"
            return false
        }
        UserDefaults.standard.set(type.rawValue, forKey: Key.micType)
        mic.type = type
        var payload = MicSetup.phantomPayload(on: type.phantomPower)
        if let gain = mic.gain { payload += MicSetup.gainPayload(type: type, dB: gain) }
        send([.micParameters(payload)], "mic type \(type.rawValue): phantom power \(type.phantomPower ? "on" : "off")")
        return true
    }

    /// Gain needs a mic type, which picks the gain key.
    func setGain(_ dB: Int) {
        guard let type = mic.type else { return }
        mic = MicSettings(type: type, gain: dB, gateThreshold: mic.gateThreshold)
        guard let gain = mic.gain else { return }
        UserDefaults.standard.set(gain, forKey: Key.micGain)
        send([.micParameters(MicSetup.gainPayload(type: type, dB: gain))], "gain \(gain) dB")
    }

    func setGate(_ dB: Int) {
        mic = MicSettings(type: mic.type, gain: mic.gain, gateThreshold: dB)
        guard let gate = mic.gateThreshold else { return }
        UserDefaults.standard.set(gate, forKey: Key.micGate)
        send([.micParameters(MicSetup.gatePayload(dB: gate))], "gate \(gate) dB")
    }

    /// Changes one processing setting: saved, and only that setting is sent.
    func updateProcessing(_ what: String, _ change: (inout MicProcessing) -> Void) {
        var single = MicProcessing()
        change(&single)
        change(&processing)
        persistProcessing()
        send([.micParameters(single.payload)], what)
    }

    private func persistProcessing() {
        if let data = try? JSONEncoder().encode(processing) { UserDefaults.standard.set(data, forKey: Key.processing) }
    }

    private func confirmPhantom() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Turn on 48 V phantom power?"
        alert.informativeText = "Only for condenser mics. Phantom power can damage ribbon mics and some older equipment. Turn it on only if a condenser mic is plugged into the GoXLR's XLR input."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Turn On 48 V")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Lighting

    func sendLighting() {
        guard let map = lighting.colourMap(features: mixer.features) else {
            status = "Every light needs both colours before the map can be sent"
            return
        }
        send([.colourMap(map)], "colours")
    }

    /// Turning an animation off leaves its last colours showing until a colour
    /// map is sent (L-122), so the map follows.
    func sendAnimation() {
        guard mixer.features.animations else {
            status = "This firmware has no animations"
            return
        }
        guard AnimationMode.available(on: info?.model ?? .mini).contains(animation.mode) else {
            status = "\(animation.mode.title) isn't available on this GoXLR"
            return
        }
        var commands = [DeviceCommand.animation(animation.payload)]
        if animation.mode == .none {
            if let map = lighting.colourMap(features: mixer.features) {
                commands.append(.colourMap(map))
            } else {
                status = "Animation off. Its last colours stay until you send colours or power-cycle the GoXLR."
            }
        }
        send(commands, "animation \(animation.mode.title)")
    }

    // MARK: Meter

    /// Views showing the meter call start and stop; it polls only while one is visible.
    func startMeter() {
        meterViews += 1
        guard meterViews == 1 else { return }
        let timer = DispatchSource.makeTimerSource(queue: link.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self, link] in
            link.withDevice { device in
                guard let device, case .success(let level)? = try? device.micLevel() else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // A read still in flight when the meter stopped is dropped.
                        guard let self, self.meter != nil else { return }
                        self.live.mic = level.dBFS
                    }
                }
            }
        }
        timer.resume()
        meter = timer
    }

    func stopMeter() {
        meterViews = max(0, meterViews - 1)
        guard meterViews == 0 else { return }
        meter?.cancel()
        meter = nil
        live.mic = nil
    }

    // MARK: Profiles

    func refreshProfiles() {
        let profiles = store.all()
        profileNames = profiles.map(\.name)
        profileParts = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0.parts) })
    }

    /// The current settings, as much of them as `parts` names. Colours only when
    /// every light is set (the GoXLR's own can't be read).
    private func currentProfile(named name: String, parts: Set<ProfilePart>) -> DeviceProfile {
        DeviceProfile(name: name, mixer: parts.contains(.mixer) ? mixer.state : nil,
                      mic: parts.contains(.mic) ? mic : MicSettings(),
                      processing: parts.contains(.mic) ? processing : nil,
                      lighting: parts.contains(.lighting) && lighting.isComplete ? lighting : nil)
    }

    @discardableResult
    func saveProfile(named name: String, parts: Set<ProfilePart> = Set(ProfilePart.allCases)) -> Bool {
        defer { refreshProfiles() }
        do {
            try store.save(currentProfile(named: name, parts: parts))
            setActiveProfile(name)
            status = "Saved profile \(name)"
            return true
        } catch {
            status = "Couldn't save \(name): \(error)"
            return false
        }
    }

    /// Saves the current settings into an existing profile, for the parts it holds.
    func updateProfile(named name: String) {
        guard let parts = profileParts[name] else { return }
        saveProfile(named: name, parts: Set(parts))
    }

    /// Applies the parts the profile holds and leaves the rest alone. A condenser
    /// in the profile still asks before 48 V goes on.
    func applyProfile(named name: String) {
        do {
            let profile = try store.load(name)
            // Ask about 48 V before changing anything, so Cancel leaves it all as it was.
            if let type = profile.mic.type, type != mic.type, !selectMicType(type) {
                status = "Profile \(name) not applied: phantom power cancelled"
                return
            }
            if let state = profile.mixer {
                var commands = mixer.apply(state)
                persistMixer()
                if buttonHandling { commands.append(mixer.lights()) }
                send(commands, "profile \(name)")
            }
            if let gain = profile.mic.gain { setGain(gain) }
            if let gate = profile.mic.gateThreshold { setGate(gate) }
            if let lighting = profile.lighting {
                self.lighting = lighting
                sendLighting()
            }
            if let incoming = profile.processing, !incoming.payload.isEmpty {
                // Settings the profile leaves unset keep their current values on the GoXLR.
                processing = processing.merging(incoming)
                persistProcessing()
                send([.micParameters(incoming.payload)], "profile \(name): mic processing")
            }
            setActiveProfile(name)
            status = "Applied \(name)"
        } catch {
            status = "Couldn't load \(name): \(error)"
        }
    }

    /// Imports an official `.goxlr` profile, or one of ours exported as JSON, under
    /// the file's name (with a number added if that name is taken). Nothing is applied.
    func importProfile(at url: URL) {
        defer { refreshProfiles() }
        do {
            if url.pathExtension.lowercased() == "json" {
                let name = try store.importProfile(from: url)
                status = "Imported \(url.lastPathComponent) as \(name)"
                return
            }
            let official = try OfficialProfile.load(contentsOf: url)
            let base = url.deletingPathExtension().lastPathComponent
            guard let name = store.availableName(base) else {
                status = "Couldn't import \(url.lastPathComponent): too many profiles named \(base)"
                return
            }
            try store.save(official.deviceProfile(named: name))
            status = "Imported \(url.lastPathComponent) as \(name). Its effects, sampler and scribbles aren't imported."
            log.notice("XLRHelper: imported an official profile as \(name, privacy: .public)")
        } catch {
            status = "Couldn't import \(url.lastPathComponent): \(error)"
        }
    }

    /// Writes the profile to a file the user picks, to copy to another Mac.
    func exportProfile(named name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".json"
        panel.allowedContentTypes = [.json]
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.data(for: name).write(to: url, options: .atomic)
            status = "Exported \(name)"
        } catch {
            status = "Couldn't export \(name): \(error)"
        }
    }

    /// Adds back any default profile whose name isn't taken.
    func addDefaultProfiles() {
        defer { refreshProfiles() }
        do {
            let added = try store.addMissing(DeviceProfile.defaults)
            status = added.isEmpty ? "All default profiles are already there" : "Added \(added.joined(separator: ", "))"
        } catch {
            status = "Couldn't add the default profiles: \(error)"
        }
    }

    func deleteProfile(named name: String) {
        do {
            try store.delete(name)
            if activeProfile == name { setActiveProfile(nil) }
        } catch {
            status = "Couldn't delete \(name): \(error)"
        }
        refreshProfiles()
    }

    private func setActiveProfile(_ name: String?) {
        activeProfile = name
        UserDefaults.standard.set(name, forKey: Key.profile)
    }

    // MARK: Sending

    /// Sends in order on the driver queue. Lights are dropped unless button
    /// handling is on (or `lights` says this call owns them), so nothing else
    /// changes the buttons' look.
    private func send(_ commands: [DeviceCommand], _ what: String, lights: Bool = false) {
        let commands = prepared(commands, lights: lights)
        guard !commands.isEmpty else { return }
        link.withDevice { [weak self] device in
            let result = Self.deliver(commands, to: device)
            log.notice("XLRHelper: \(what, privacy: .public): \(result, privacy: .public)")
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.status = "\(what): \(result)" } }
        }
    }

    private func prepared(_ commands: [DeviceCommand], lights: Bool) -> [DeviceCommand] {
        buttonHandling || lights ? commands : commands.filter { if case .buttonLights = $0 { return false }; return true }
    }

    nonisolated private static func deliver(_ commands: [DeviceCommand], to device: XLRDevice?) -> String {
        guard let device else { return "saved; the driver isn't running" }
        var failures = [String]()
        for command in commands {
            do {
                if let failure = try device.send(command).failure { failures.append("\(command.summary): \(failure)") }
            } catch {
                failures.append("\(command.summary): \(error)")
            }
        }
        return failures.isEmpty ? "done" : failures.joined(separator: "; ")
    }

    /// At quit: release this app's mutes and lights, waiting for the commands,
    /// so no channel stays muted with nothing left to unmute it.
    func releaseForQuit() {
        if mixerSavePending { persistMixer() }
        guard buttonHandling else { return }
        let commands = prepared(mixer.releaseAllMutes() + [Self.lightsAsFound], lights: true)
        let done = DispatchSemaphore(value: 0)
        link.withDevice { device in
            log.notice("XLRHelper: quitting; mutes released: \(Self.deliver(commands, to: device), privacy: .public)")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    func checkTrust() {
        link.withDevice { device in
            guard let client = device as? DriverClient else { return log.notice("XLRHelper: trust check: driver not running") }
            do {
                let trusted = try client.isTrusted()
                log.notice("XLRHelper: trust check: trusted \(trusted ? 1 : 0, privacy: .public)")
            } catch {
                log.notice("XLRHelper: trust check: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Device identity: shown on request, never logged or stored (SPEC.md section 7).
    func readSerial(_ done: @escaping (String) -> Void) {
        link.withDevice { device in
            let text: String
            switch (try? device?.serial()) ?? nil {
            case .success(let serial)?: text = serial
            case .failure(let failure)?: text = "\(failure)"
            case nil: text = "the driver isn't running"
            }
            DispatchQueue.main.async { done(text) }
        }
    }
}
