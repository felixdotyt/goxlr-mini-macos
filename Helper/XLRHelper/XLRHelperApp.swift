// GoXLR Mini Mac: embeds the XLR driver and activates it, keeps the GoXLR's mic
// settings applied, handles its buttons, and holds the mixer, routing and
// profiles (PROMPT.md Phases 4, 5 and 7). It lives in the menu bar (no Dock
// icon) and can open at login; the window opens from the menu.
//
// Launch options: `--activate` or `--deactivate`, plus `--quit-when-done` to exit
// after the request finishes; `--check-trust` logs whether the driver trusts this
// app (signed by the driver's team); `--mic-type dynamic|jack|condenser` saves and
// applies a mic type (for a condenser it only opens the confirmation and never
// answers it); `--open-at-login on|off` registers or removes the login item;
// `--simulate` uses GoXLRKit's simulator instead of the driver; `--open-window`
// opens the window at launch (otherwise it opens from the menu); `--snapshot <dir>`
// renders each window page to a PNG there and quits (for reviewing the layout).
//
// Phantom power (48 V) can only be switched on here: the driver accepts it only
// from team-signed clients (ADR 0003 consequence 2), and this app asks the user
// to confirm a condenser mic every time. The Mini turns 48 V on at every power-up
// (LEDGER L-130), so whenever the driver becomes ready this app turns it off again
// unless the saved mic type is a condenser. It never turns 48 V on by itself.

import Foundation
import GoXLRKit
import os
import ServiceManagement
import SwiftUI
import SystemExtensions

let driverIdentifier = DriverClient.bundleIdentifier
let log = Logger(subsystem: "yt.felix.xlr.helper", category: "extension")

@MainActor
final class ExtensionController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Idle"
    private let quitWhenDone = CommandLine.arguments.contains("--quit-when-done")

    func activate() { submit(.activationRequest(forExtensionWithIdentifier: driverIdentifier, queue: .main), "activate") }
    func deactivate() { submit(.deactivationRequest(forExtensionWithIdentifier: driverIdentifier, queue: .main), "deactivate") }

    private func submit(_ request: OSSystemExtensionRequest, _ verb: String) {
        report("Requesting \(verb) of \(driverIdentifier)")
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func report(_ message: String) {
        status = message
        log.notice("XLRHelper: \(message, privacy: .public)")
    }

    private func finish(_ message: String) {
        report(message)
        if quitWhenDone { NSApplication.shared.terminate(nil) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.notice("XLRHelper: replacing \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.report("Needs approval in System Settings → General → Login Items & Extensions → Driver Extensions") }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let text = result == .completed ? "completed" : "will complete after reboot"
        Task { @MainActor in self.finish("Request finished: \(text)") }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        Task { @MainActor in self.finish("Request failed: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)") }
    }
}

/// Opening the helper at login (SMAppService), so the saved mic type is applied
/// whenever the Mini attaches. The user can also turn it off in System Settings.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var note = ""

    init() { refresh() }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note = ""
        } catch {
            note = error.localizedDescription
        }
        refresh()
        log.notice("XLRHelper: open at login \(on ? "on" : "off", privacy: .public): \(self.describe(), privacy: .public)")
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        if status == .requiresApproval { note = "Allow GoXLR Mini Mac in System Settings → General → Login Items." }
    }

    private func describe() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "needs approval in System Settings"
        case .notRegistered: return "not registered" + (note.isEmpty ? "" : " (\(note))")
        case .notFound: return "not found" + (note.isEmpty ? "" : " (\(note))")
        @unknown default: return "unknown"
        }
    }
}

/// Handles the launch options at startup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let controller = ExtensionController()
    @MainActor static let session = DeviceSession(simulated: CommandLine.arguments.contains("--simulate"))
    @MainActor static let loginItem = LoginItem()
    @MainActor static var sessionStarted = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(_ option: String) -> String? {
            args.firstIndex(of: option).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        if let directory = value("--snapshot") {
            Snapshot.render(to: URL(fileURLWithPath: directory), session: Self.session, extensions: Self.controller,
                            loginItem: Self.loginItem)
            NSApplication.shared.terminate(nil)
            return
        }
        // One session per user: a second copy, or a one-shot activation launch
        // (goxlrctl driver activate), would handle buttons and lights in
        // parallel with the running app.
        let oneShot = args.contains("--activate") || args.contains("--deactivate") || args.contains("--quit-when-done")
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if oneShot || !others.isEmpty {
            log.notice("XLRHelper: not starting a device session (\(oneShot ? "one-shot launch" : "another copy is running", privacy: .public))")
        } else {
            Self.session.start()
            Self.sessionStarted = true
        }
        if args.contains("--activate") { Self.controller.activate() }
        if args.contains("--deactivate") { Self.controller.deactivate() }
        if args.contains("--check-trust") {
            if Self.sessionStarted { Self.session.checkTrust() } else { log.notice("XLRHelper: trust check skipped: no device session in this copy") }
        }
        if let type = value("--mic-type").flatMap(MicType.init(rawValue:)) { Self.session.selectMicType(type) }
        if let state = value("--open-at-login"), ["on", "off"].contains(state) { Self.loginItem.set(state == "on") }
        // At login nobody asked for the window: SwiftUI may open it anyway, so
        // close it unless `--open-window` was passed.
        let keepWindow = args.contains("--open-window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
            if !keepWindow { windows.forEach { $0.close() } }
            log.notice("XLRHelper: launched; main window \(windows.isEmpty ? "not open" : keepWindow ? "open" : "closed", privacy: .public)")
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        if Self.sessionStarted { Self.session.releaseForQuit() }
    }
}

/// Renders each window page offscreen into PNGs, through AppKit so its controls draw.
@MainActor
enum Snapshot {
    static func render(to directory: URL, session: DeviceSession, extensions: ExtensionController, loginItem: LoginItem) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for page in Page.allCases {
            let view = SnapshotPage(page: page, session: session, extensions: extensions, loginItem: loginItem)
            write(view, size: NSSize(width: 820, height: 640), to: directory.appendingPathComponent("\(page.rawValue).png"))
        }
        write(MenuContent(session: session, loginItem: loginItem).background(Color(nsColor: .windowBackgroundColor)),
              size: NSSize(width: 460, height: 330), to: directory.appendingPathComponent("menu.png"))
    }

    private static func write<V: View>(_ view: V, size: NSSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

struct SnapshotPage: View {
    let page: Page
    @ObservedObject var session: DeviceSession
    @ObservedObject var extensions: ExtensionController
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        ScrollView {
            Group {
                switch page {
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
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The menu bar icon. It's drawn at launch, before any window, so it's where
/// `--open-window` can reach SwiftUI's openWindow.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "slider.vertical.3")
            .accessibilityLabel("GoXLR Mini Mac")
            .onAppear {
                if CommandLine.arguments.contains("--open-window") { openWindow(id: "main") }
            }
    }
}

@main
struct XLRHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var controller = AppDelegate.controller
    @ObservedObject private var session = AppDelegate.session
    @ObservedObject private var loginItem = AppDelegate.loginItem

    var body: some Scene {
        MenuBarExtra {
            MenuContent(session: session, loginItem: loginItem)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
        Window("GoXLR Mini Mac", id: "main") {
            MainWindow(session: session, extensions: controller, loginItem: loginItem)
        }
        .windowResizability(.contentMinSize)
    }
}
