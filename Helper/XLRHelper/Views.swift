// The helper's window and menu bar views. Sliders send when released, not
// while dragging, so a drag is one command.

import GoXLRKit
import SwiftUI
import UniformTypeIdentifiers

enum Page: String, CaseIterable, Identifiable {
    case mixer, routing, mic, buttons, lighting, profiles, device

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var icon: String {
        switch self {
        case .mixer: return "slider.vertical.3"
        case .routing: return "square.grid.3x3"
        case .mic: return "mic"
        case .buttons: return "button.programmable"
        case .lighting: return "lightbulb"
        case .profiles: return "tray.full"
        case .device: return "info.circle"
        }
    }
}

struct MainWindow: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var extensions: ExtensionController
    @ObservedObject var loginItem: LoginItem
    @State private var page: Page? = .mixer

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch page ?? .mixer {
                        case .mixer: MixerPage(session: session)
                        case .routing: RoutingPage(session: session)
                        case .mic: MicPage(session: session)
                        case .buttons: ButtonsPage(session: session)
                        case .lighting: LightingPage(session: session)
                        case .profiles: ProfilesPage(session: session)
                        case .device: DevicePage(session: session, extensions: extensions, loginItem: loginItem)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                Divider()
                StatusBar(session: session)
            }
            .navigationTitle(page?.title ?? "GoXLR Mini Mac")
        }
        .frame(minWidth: 780, minHeight: 540)
    }
}

struct StatusBar: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.connected ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(session.connected ? (session.simulated ? "Simulator" : "GoXLR Mini connected") : "No device")
            Divider().frame(height: 12)
            Text(session.status).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// A heading with an explanation under it.
struct PageSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }
}

/// A control with a fixed-width label column, so rows line up.
struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 130, alignment: .leading)
            content
        }
    }
}

// MARK: Mixer

struct MixerPage: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        PageSection(title: "Faders",
                    note: "The channel each fader controls, its mute button and its lights. The GoXLR can't report these, so a fader shows \"Not set\" until you choose one here or apply a profile.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Fader").gridColumnAlignment(.leading)
                    Text("Channel")
                    Text("Position")
                    Text("Mute")
                    Text("Mute button")
                    Text("Display")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Fader.allCases, id: \.self) { fader in
                    GridRow {
                        Text(fader.title).bold()
                        channelPicker(fader)
                        FaderPosition(live: session.live, fader: fader)
                        muteButton(fader)
                        Picker("", selection: Binding(get: { session.mixer.state.muteFunction(fader) },
                                                      set: { session.setMuteFunction(fader, $0) })) {
                            ForEach(MuteFunction.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 170)
                        displayPicker(fader)
                    }
                }
            }
        }
        PageSection(title: "Volumes", note: "0–100 %. A channel shows \"Not set\" until it has been set here, by a profile or by moving its fader; the GoXLR keeps its own level until then. After a power-up the GoXLR holds every fader's channel at 0 until the fader moves, so the app sends each fader's last level when the GoXLR attaches.") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Channel.allCases, id: \.self) { channel in
                    VolumeRow(channel: channel, value: session.mixer.state.volumes[channel]) { session.setVolume(channel, $0) }
                }
            }
        }
    }

    private func channelPicker(_ fader: Fader) -> some View {
        Picker("", selection: Binding(get: { session.mixer.state.faders[fader] },
                                      set: { if let channel = $0 { session.setFader(fader, channel) } })) {
            if session.mixer.state.faders[fader] == nil { Text("Not set").tag(Channel?.none) }
            ForEach(Channel.faderChannels, id: \.self) { Text($0.title).tag(Channel?.some($0)) }
        }
        .labelsHidden().frame(width: 120)
    }

    private func muteButton(_ fader: Fader) -> some View {
        let state = session.mixer.muteState(fader)
        return Button(state.isMuted ? "Muted" : "Mute") { session.toggleMute(fader) }
            .tint(state.isMuted ? .red : nil)
            .buttonStyle(.bordered)
            .disabled(!session.buttonHandling || !session.mixer.applied.faders.contains(fader))
            .help(!session.buttonHandling ? "Turn on button handling (Buttons page) to mute from here and with the GoXLR's buttons"
                  : !session.mixer.applied.faders.contains(fader) ? "Choose this fader's channel first"
                  : state == .mutedToX ? "Muted to one output" : state.isMuted ? "Muted to all" : "Mute this fader's channel")
    }

    private func displayPicker(_ fader: Fader) -> some View {
        let options: [(String, FaderDisplay)] = [("Two colours", FaderDisplay(gradient: false, meter: false)),
                                                 ("Gradient", FaderDisplay(gradient: true, meter: false)),
                                                 ("Meter", FaderDisplay(gradient: false, meter: true)),
                                                 ("Gradient meter", FaderDisplay(gradient: true, meter: true))]
        return Picker("", selection: Binding(get: { session.mixer.state.faderDisplays[fader] },
                                             set: { if let display = $0 { session.setFaderDisplay(fader, display) } })) {
            if session.mixer.state.faderDisplays[fader] == nil { Text("Not set").tag(FaderDisplay?.none) }
            ForEach(options, id: \.0) { Text($0.0).tag(FaderDisplay?.some($0.1)) }
        }
        .labelsHidden().frame(width: 140)
    }
}

struct FaderPosition: View {
    @ObservedObject var live: LiveLevels
    let fader: Fader

    var body: some View {
        let index = Int(fader.rawValue)
        Text(index < live.faders.count ? "\(Int((Double(live.faders[index]) / 2.55).rounded())) %" : "—")
            .monospacedDigit().foregroundStyle(.secondary)
    }
}

/// A slider that sends when a drag ends, and at once for keyboard or
/// VoiceOver changes (which don't report editing).
struct CommitSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let commit: (Double) -> Void
    @State private var editing = false
    @State private var committed: Double?
    @State private var startValue: Double?

    var body: some View {
        Slider(value: $value, in: range, step: step) { isEditing in
            editing = isEditing
            if isEditing {
                startValue = value
            } else if value != startValue {
                // A click that doesn't move the slider sends nothing (an unset
                // setting's placeholder would otherwise be sent).
                send()
            }
        }
        .onChange(of: value) { _, _ in if !editing { send() } }
    }

    private func send() {
        guard committed != value else { return }
        committed = value
        commit(value)
    }
}

struct VolumeRow: View {
    let channel: Channel
    let value: UInt8?
    let set: (UInt8) -> Void
    @State private var draft = 0.0

    var body: some View {
        GridRow {
            Text(channel.title).frame(width: 100, alignment: .leading)
            // Loading or an outside change sets `draft` too; only a real change is sent.
            CommitSlider(value: $draft, range: 0...255) { new in
                let level = UInt8(new.rounded())
                if level != value { set(level) }
            }
            .frame(minWidth: 260)
            .opacity(value == nil ? 0.5 : 1)
            Text(value == nil && draft == 0 ? "Not set" : "\(Int((draft / 2.55).rounded())) %")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
        .onAppear { draft = Double(value ?? 0) }
        .onChange(of: value) { _, new in if let new { draft = Double(new) } }
    }
}

// MARK: Routing

struct RoutingPage: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        PageSection(title: "Routing",
                    note: "Which inputs reach which outputs. The GoXLR can't report its routing, so an input you haven't set shows \"Not set\"; your first change to it writes its whole row, turning off the outputs you haven't ticked. \"Saved, not sent\" means the GoXLR has restarted since; it gets the row again with your next change, a profile, or at attach when restoring the mixer is on.") {
            if !session.mixer.canWriteRouting {
                Text("This GoXLR's firmware has Stream Mix 2, which this app doesn't handle yet, so routing changes are off.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Grid(alignment: .center, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(RoutingOutput.allCases, id: \.self) { Text($0.title).font(.caption).foregroundStyle(.secondary) }
                    Text("")
                }
                ForEach(RoutingInput.allCases, id: \.self) { input in
                    GridRow {
                        Text(input.title).frame(width: 90, alignment: .leading)
                        ForEach(RoutingOutput.allCases, id: \.self) { output in
                            Toggle("", isOn: Binding(get: { session.mixer.state.routing[input]?.contains(output) ?? false },
                                                     set: { session.setRouting(input, output, $0) }))
                                .labelsHidden()
                                .help("\(input.title) → \(output.title)")
                        }
                        Text(session.mixer.state.routing[input] == nil ? "Not set"
                             : session.mixer.applied.routing.contains(input) ? "" : "Saved, not sent")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                    }
                }
            }
            .disabled(!session.mixer.canWriteRouting)
        }
        PageSection(title: "Feedback", note: "Routing the mic to Headphones or Line Out lets you hear yourself; with speakers on Line Out that can feed back. Keep the volume low when you try it.") {
            EmptyView()
        }
    }
}

// MARK: Mic

struct MicPage: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        PageSection(title: "Microphone",
                    note: "Saved here and sent whenever the GoXLR attaches. 48 V phantom power goes on only after you confirm a condenser mic; the GoXLR itself turns 48 V on at every power-up, so for other mics this app turns it off again at attach.") {
            MicControls(session: session)
        }
        PageSection(title: "Gate", note: "Turns the mic down while you aren't talking. It opens when the mic's level rises above the threshold, set with the mic controls above, in dB as on the level meter. Every control here was checked on the Mini (L-137, L-139).") {
            ProcessingSlider(title: "Attenuation", value: session.processing.gateAttenuation.flatMap { MicProcessing.gateAttenuations.firstIndex(of: $0) },
                             count: MicProcessing.gateAttenuations.count, label: { "\(MicProcessing.gateAttenuations[$0]) dB" },
                             help: "How much quieter the mic is while the gate is shut. −61 dB is silence; less keeps some room sound.") { index in
                session.updateProcessing("gate attenuation") { $0.gateAttenuation = MicProcessing.gateAttenuations[index] }
            }
            ProcessingSlider(title: "Attack", value: session.processing.gateAttack, count: MicProcessing.gateTimes.count,
                             label: { "\(MicProcessing.gateTimes[$0]) ms" },
                             help: "How fast it opens when you start talking. Short keeps first syllables; measured: 10 ms opens in about 13 ms, 1000 ms in about 250 ms.") { index in
                session.updateProcessing("gate attack") { $0.gateAttack = index }
            }
            ProcessingSlider(title: "Release", value: session.processing.gateRelease, count: MicProcessing.gateTimes.count,
                             label: { "\(MicProcessing.gateTimes[$0]) ms" },
                             help: "How long it stays open after you stop. Too short cuts word endings; measured: 200 ms shuts after about 70 ms, 1000 ms after about 460 ms.") { index in
                session.updateProcessing("gate release") { $0.gateRelease = index }
            }
        }
        PageSection(title: "Compressor", note: "Turns loud moments down so your level stays even. Checked on the Mini (L-139).") {
            ProcessingSlider(title: "Threshold", value: session.processing.compressorThreshold.map { $0 - MicProcessing.compressorThresholds.lowerBound },
                             count: MicProcessing.compressorThresholds.count,
                             label: { "\($0 + MicProcessing.compressorThresholds.lowerBound) dB" },
                             help: "Above this level (dB, like the meter) it starts turning the mic down. At 0 dB it never acts; set it a few dB below where your louder speech peaks on the meter.") { index in
                session.updateProcessing("compressor threshold") { $0.compressorThreshold = index + MicProcessing.compressorThresholds.lowerBound }
            }
            ProcessingSlider(title: "Ratio", value: session.processing.compressorRatio, count: MicProcessing.compressorRatios.count,
                             label: { String(format: "%g:1", MicProcessing.compressorRatios[$0]) },
                             help: "How hard. At 4:1, 8 dB above the threshold comes out 2 dB above it; 1:1 is off.") { index in
                session.updateProcessing("compressor ratio") { $0.compressorRatio = index }
            }
            ProcessingSlider(title: "Attack", value: session.processing.compressorAttack, count: MicProcessing.compressorAttacks.count,
                             label: { "\(MicProcessing.compressorAttacks[$0]) ms" },
                             help: "How fast it reacts to a loud sound. Longer lets the start of each word through.") { index in
                session.updateProcessing("compressor attack") { $0.compressorAttack = index }
            }
            ProcessingSlider(title: "Release", value: session.processing.compressorRelease, count: MicProcessing.compressorReleases.count,
                             label: { "\(MicProcessing.compressorReleases[$0]) ms" },
                             help: "How fast it lets go after a loud sound. The Mini starts out at about 100 ms.") { index in
                session.updateProcessing("compressor release") { $0.compressorRelease = index }
            }
            ProcessingSlider(title: "Make-up gain", value: session.processing.compressorMakeUp, count: MicProcessing.makeUpGains.count,
                             label: { "+\($0) dB" },
                             help: "Turns the whole mic back up after compressing.") { index in
                session.updateProcessing("compressor make-up") { $0.compressorMakeUp = index }
            }
        }
        PageSection(title: "Bleep", note: "The Bleep button's tone comes from the GoXLR and replaces your mic while held; this sets how loud it is. You hear it in your headphones only while the mic is routed to Headphones.") {
            ProcessingSlider(title: "Level", value: session.processing.bleepLevel.map { $0 - MicProcessing.bleepLevels.lowerBound },
                             count: MicProcessing.bleepLevels.count,
                             label: { "\($0 + MicProcessing.bleepLevels.lowerBound) dB" }) { index in
                session.updateProcessing("bleep level") { $0.bleepLevel = index + MicProcessing.bleepLevels.lowerBound }
            }
        }
        PageSection(title: "Not yet available",
                    note: "The Mini's 6-band EQ: of goxlr-utility's six EQ keys, only the 90 Hz band (and weakly 8 kHz) changed anything on this Mini, so the EQ waits for more testing.") {
            EmptyView()
        }
    }
}

/// Mic type, gain and gate; shared by the Mic page and the menu bar.
struct MicControls: View {
    @ObservedObject var session: DeviceSession
    @State private var gain = 25.0
    @State private var gate = Double(MicSettings.gateRange.lowerBound)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mic:", selection: Binding(get: { session.mic.type }, set: { if let type = $0 { session.selectMicType(type) } })) {
                if session.mic.type == nil { Text("Not set").tag(MicType?.none) }
                ForEach(MicType.allCases, id: \.self) { Text($0.title).tag(MicType?.some($0)) }
            }
            .pickerStyle(.radioGroup)
            HStack {
                Text("Gain").frame(width: 40, alignment: .leading)
                CommitSlider(value: $gain, range: range(MicSettings.gainRange)) { new in
                    if Int(new) != session.mic.gain { session.setGain(Int(new)) }
                }
                .opacity(session.mic.gain == nil ? 0.5 : 1)
                Text(session.mic.gain == nil ? "Not set" : "\(Int(gain)) dB").monospacedDigit().frame(width: 90, alignment: .trailing)
            }
            .disabled(session.mic.type == nil)
            MicLevelRow(live: session.live)
            HStack {
                Text("Gate").frame(width: 40, alignment: .leading)
                CommitSlider(value: $gate, range: range(MicSettings.gateRange)) { new in
                    if Int(new) != session.mic.gateThreshold { session.setGate(Int(new)) }
                }
                .opacity(session.mic.gateThreshold == nil ? 0.5 : 1)
                Text(session.mic.gateThreshold == nil ? "Not set"
                     : Int(gate) == MicSettings.gateRange.lowerBound ? "\(Int(gate)) dB (open)" : "\(Int(gate)) dB")
                    .monospacedDigit().frame(width: 90, alignment: .trailing)
            }
        }
        .frame(maxWidth: 520)
        .onAppear {
            load()
            session.startMeter()
        }
        .onDisappear { session.stopMeter() }
        .onChange(of: session.mic) { _, _ in load() }
    }

    private func load() {
        if let saved = session.mic.gain { gain = Double(saved) }
        if let saved = session.mic.gateThreshold { gate = Double(saved) }
    }

    private func range(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }
}

/// A setting chosen from a table by index; shows "Not set" until set.
struct ProcessingSlider: View {
    let title: String
    let value: Int?
    let count: Int
    let label: (Int) -> String
    var help: String?
    let set: (Int) -> Void
    @State private var draft = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).frame(width: 130, alignment: .leading)
                CommitSlider(value: $draft, range: 0...Double(count - 1)) { new in
                    if Int(new) != value { set(Int(new)) }
                }
                .opacity(value == nil ? 0.5 : 1)
                Text(value == nil ? "Not set" : label(clamped(Int(draft)))).monospacedDigit().frame(width: 90, alignment: .trailing)
            }
            if let help {
                Text(help).font(.caption).foregroundStyle(.secondary).padding(.leading, 138)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560)
        .onAppear { draft = Double(clamped(value ?? 0)) }
        .onChange(of: value) { _, new in if let new { draft = Double(clamped(new)) } }
    }

    private func clamped(_ index: Int) -> Int { min(max(index, 0), count - 1) }
}

struct MicLevelRow: View {
    @ObservedObject var live: LiveLevels

    var body: some View {
        HStack {
            Text("Level").frame(width: 40, alignment: .leading)
            LevelMeter(dBFS: live.mic)
            Text(live.mic.map { String(format: "%.0f dB", $0) } ?? "—")
                .monospacedDigit().frame(width: 90, alignment: .trailing)
        }
    }
}

/// The mic's peak level from -60 to 0 dBFS, green to amber to red. The gate
/// threshold isn't marked: its scale relative to this meter is unknown.
struct LevelMeter: View {
    let dBFS: Double?

    var body: some View {
        GeometryReader { geometry in
            let fraction = max(0, min(1, ((dBFS ?? -90) + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * fraction) }
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.1), value: dBFS)
        .accessibilityLabel("Mic level")
        .accessibilityValue(dBFS.map { String(format: "%.0f decibels", $0) } ?? "not measured")
    }
}

// MARK: Buttons

extension ButtonLight {
    var title: String {
        switch self {
        case .colour1: return "First colour"
        case .colour2: return "Second colour"
        case .dimmedColour1: return "Dimmed"
        case .flashing: return "Flashing"
        case .dimmedColour2: return "Dimmed second colour"
        }
    }
}

struct ButtonsPage: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        PageSection(title: "Button handling",
                    note: "The GoXLR only reports button presses; the app does what they mean. When this is on, the fader mute buttons mute their channel (hold one to mute it to everything), Cough mutes the mic, and the buttons light up to match. Turning it on sends the fader channels and routing set in this app (the buttons act on them) and changes the buttons' lights; turning it off unmutes what the app muted and puts the lights back.") {
            Toggle("Handle the GoXLR's buttons", isOn: $session.buttonHandling)
        }
        PageSection(title: "Cough button") {
            LabeledRow(label: "Mode") {
                Picker("Mode", selection: Binding(get: { session.mixer.state.cough.toggle },
                                                  set: { session.setCough(CoughSettings(function: session.mixer.state.cough.function, toggle: $0)) })) {
                    Text("Mute while held").tag(false)
                    Text("Press to toggle (hold to mute to all)").tag(true)
                }
                .labelsHidden().frame(width: 300, alignment: .leading)
            }
            LabeledRow(label: "Mutes") {
                Picker("Mutes", selection: Binding(get: { session.mixer.state.cough.function },
                                                   set: { session.setCough(CoughSettings(function: $0, toggle: session.mixer.state.cough.toggle)) })) {
                    ForEach(MuteFunction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 300, alignment: .leading)
            }
        }
        PageSection(title: "Lights",
                    note: "How a button looks when it isn't active. Active buttons use their first colour; a mute made by holding a button flashes. On a GoXLR whose two button colours are the same (as on the Mini tested so far), only Dimmed shows a difference, and flashing isn't visible.") {
            LabeledRow(label: "Inactive buttons") {
                Picker("Inactive buttons", selection: Binding(get: { session.mixer.state.offLight }, set: { session.setOffLight($0) })) {
                    ForEach([ButtonLight.dimmedColour1, .colour2, .dimmedColour2], id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 300, alignment: .leading)
            }
        }
        PageSection(title: "Mute to one output",
                    note: "A fader or cough button set to mute to stream, chat, headphones or line out takes its channel out of that output's routing, so it needs that input's routing set on the Routing page. Until then it mutes to all.") {
            EmptyView()
        }
    }
}

// MARK: Lighting

extension RGB {
    var color: Color { Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }

    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent))
    }
}

struct LightingPage: View {
    @ObservedObject var session: DeviceSession
    @State private var everything = Color(red: 0, green: 1, blue: 1)

    var body: some View {
        PageSection(title: "Colours",
                    note: "The GoXLR can't report its colours, so these start unset (grey): pick each one, set them all to one colour, or apply a profile that has colours. A fader strip shows where its knob is only when its two colours differ (black above the knob is the usual look). Nothing changes on the GoXLR until you press Send; then these colours stay until it's power-cycled, when it goes back to the colours it has stored.") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(LightTarget.allCases, id: \.self) { target in
                    GridRow {
                        Text(target.title).frame(width: 120, alignment: .leading)
                        colourPicker(target, 0, target.colourTitles.0)
                        colourPicker(target, 1, target.colourTitles.1)
                    }
                }
            }
            HStack {
                ColorPicker("Set all to", selection: $everything, supportsOpacity: false)
                Button("Apply to All") { session.lighting = .uniform(RGB(everything)) }
            }
            Button("Send Colours to the GoXLR") { session.sendLighting() }
                .disabled(!session.connected || !session.lighting.isComplete)
        }
        PageSection(title: "Animation",
                    note: "Animated lighting on the buttons and faders. Sent when you press Send; None turns it off and resends the colours above.") {
            LabeledRow(label: "Mode") {
                Picker("Mode", selection: $session.animation.mode) {
                    ForEach(AnimationMode.available(on: session.info?.model ?? .mini), id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 220, alignment: .leading)
            }
            LabeledRow(label: "Modifier 1") {
                Slider(value: Binding(get: { Double(session.animation.modifier1) }, set: { session.animation.modifier1 = UInt8($0) }),
                       in: 0...100, step: 1).frame(width: 220)
                Text("\(session.animation.modifier1)").monospacedDigit()
            }
            LabeledRow(label: "Modifier 2") {
                Slider(value: Binding(get: { Double(session.animation.modifier2) }, set: { session.animation.modifier2 = UInt8($0) }),
                       in: 0...100, step: 1).frame(width: 220)
                Text("\(session.animation.modifier2)").monospacedDigit()
            }
            LabeledRow(label: "Waterfall") {
                Picker("Waterfall", selection: $session.animation.waterfall) {
                    ForEach(Waterfall.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 220, alignment: .leading)
            }
            Button("Send Animation to the GoXLR") { session.sendAnimation() }
                .disabled(!session.connected || !session.mixer.features.animations)
        }
    }

    private func colourPicker(_ target: LightTarget, _ index: Int, _ title: String) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .trailing)
            picker(target, index, title).labelsHidden()
        }
    }

    private func picker(_ target: LightTarget, _ index: Int, _ title: String) -> some View {
        ColorPicker(title, selection: Binding(
            get: { session.lighting.colours[target]?[safe: index]?.color ?? Color.gray.opacity(0.4) },
            set: { color in
                let unset = RGB(red: 128, green: 128, blue: 128)
                var pair = session.lighting.colours[target] ?? [unset, unset]
                pair[index] = RGB(color)
                session.lighting.colours[target] = pair
            }), supportsOpacity: false)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: Profiles

struct ProfilesPage: View {
    @ObservedObject var session: DeviceSession
    @State private var name = ""
    @State private var parts = Set(ProfilePart.allCases)
    @State private var importing = false

    var body: some View {
        PageSection(title: "Profiles", note: "A profile holds some or all of: the mixer (faders, volumes, routing, mute buttons, displays), the mic (type, gain, gate, compressor, bleep) and the colours. Applying one changes only what it holds. Update saves the current settings into it.") {
            if session.profileNames.isEmpty { Text("No profiles yet.").foregroundStyle(.secondary) }
            ForEach(session.profileNames, id: \.self) { profile in
                HStack {
                    Image(systemName: profile == session.activeProfile ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(profile == session.activeProfile ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile)
                        Text((session.profileParts[profile] ?? []).map(\.title).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") { session.applyProfile(named: profile) }
                    Button("Update") { session.updateProfile(named: profile) }
                        .help("Save the current settings into \(profile), for the parts it holds")
                    Button("Export…") { session.exportProfile(named: profile) }
                    Button("Delete", role: .destructive) { session.deleteProfile(named: profile) }
                }
                .frame(maxWidth: 620)
            }
        }
        PageSection(title: "Save as a new profile", note: "Choose what it holds. Colours can be saved once every light has a colour on the Lighting page.") {
            HStack(spacing: 16) {
                ForEach(ProfilePart.allCases, id: \.self) { part in
                    Toggle(part.title, isOn: Binding(get: { parts.contains(part) },
                                                     set: { if $0 { parts.insert(part) } else { parts.remove(part) } }))
                        .disabled(part == .lighting && !session.lighting.isComplete)
                }
            }
            HStack {
                TextField("Profile name", text: $name).frame(width: 220)
                Button("Save") {
                    if session.saveProfile(named: name, parts: parts) { name = "" }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || parts.isEmpty)
            }
        }
        PageSection(title: "Import",
                    note: "A profile exported from this app (.json), for example on another Mac, or one saved by TC-Helicon's GoXLR app (.goxlr): its faders, volumes, routing, fader displays, mute buttons and the Mini's colours come across; effects, sampler and scribbles don't. Importing only adds it to the list.") {
            HStack {
                Button("Import Profile…") { importing = true }
                    .fileImporter(isPresented: $importing,
                                  allowedContentTypes: [.json, UTType(filenameExtension: "goxlr") ?? .data]) { result in
                        if case .success(let url) = result {
                            let access = url.startAccessingSecurityScopedResource()
                            session.importProfile(at: url)
                            if access { url.stopAccessingSecurityScopedResource() }
                        }
                    }
                Button("Add Default Profiles") { session.addDefaultProfiles() }
                    .help("Adds back any of the starting profiles whose name isn't taken")
            }
        }
        PageSection(title: "At attach",
                    note: "The GoXLR forgets its mixer at every power-up. With this on, the app sends the current faders, volumes, routing and displays each time it attaches. The mic settings are always sent.") {
            Toggle("Restore the mixer when the GoXLR attaches", isOn: $session.restoreMixerOnAttach)
        }
        .onAppear { session.refreshProfiles() }
    }
}

// MARK: Device

struct DevicePage: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var extensions: ExtensionController
    @ObservedObject var loginItem: LoginItem
    @State private var serial: String?

    var body: some View {
        PageSection(title: "Device") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Connection", session.connected ? (session.simulated ? "Simulator" : "Connected") : "Not connected")
                if let info = session.info {
                    row("Model", info.model == .full ? "GoXLR" : info.model == .mini ? "GoXLR Mini" : "Unknown")
                    row("Firmware", info.versions?.firmwareText ?? info.firmware.map(String.init).joined(separator: "."))
                    row("Driver", "v\(info.driverVersion), interface \(info.abiVersion), writes up to tier \(info.writeTier)")
                    row("Features", features)
                }
                GridRow {
                    Text("Serial").foregroundStyle(.secondary)
                    if let serial {
                        Text(serial).textSelection(.enabled)
                    } else {
                        Button("Show") { session.readSerial { serial = $0 } }.disabled(!session.connected)
                    }
                }
            }
        }
        PageSection(title: "Driver", note: "The driver controls the GoXLR; macOS asks you to allow it once in System Settings.") {
            Text(extensions.status).font(.callout).textSelection(.enabled)
            HStack {
                Button("Activate Driver") { extensions.activate() }
                Button("Deactivate Driver") { extensions.deactivate() }
            }
        }
        PageSection(title: "App", note: "The app has to run for the mic settings and buttons to work, so it can open at login.") {
            Toggle("Open at Login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
            if !loginItem.note.isEmpty { Text(loginItem.note).font(.caption) }
        }
        .onAppear { loginItem.refresh() }
    }

    private var features: String {
        let f = session.mixer.features
        var list = [String]()
        if f.animations { list.append("animations") }
        if f.submixes { list.append("submixes") }
        if f.mix2 { list.append("Stream Mix 2") }
        return list.isEmpty ? "none" : list.joined(separator: ", ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: Menu bar

struct MenuContent: View {
    @ObservedObject var session: DeviceSession
    @ObservedObject var loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusBar(session: session).padding(.horizontal, -12)
            MicControls(session: session)
            if !session.profileNames.isEmpty {
                let active = session.activeProfile.flatMap { session.profileNames.contains($0) ? $0 : nil }
                Picker("Profile:", selection: Binding(get: { active ?? "" },
                                                      set: { if !$0.isEmpty { session.applyProfile(named: $0) } })) {
                    if active == nil { Text("None").tag("") }
                    ForEach(session.profileNames, id: \.self) { Text($0).tag($0) }
                }
                .help("Applies the profile you choose")
            }
            Divider()
            HStack {
                Button("Open GoXLR Mini Mac…") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Toggle("Open at Login", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
            }
            if !loginItem.note.isEmpty { Text(loginItem.note).font(.caption) }
            Button("Quit GoXLR Mini Mac") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 460)
        .onAppear { loginItem.refresh() }
    }
}
