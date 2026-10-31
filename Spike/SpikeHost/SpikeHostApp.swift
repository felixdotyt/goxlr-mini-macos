// Phase 0 signing spike host: activates and deactivates the embedded HelloDriver dext.
// Launch with `--activate` or `--deactivate` to act without clicking.

import Foundation
import os
import SwiftUI
import SystemExtensions

let driverIdentifier = "yt.felix.xlr.spike.driver"
let log = Logger(subsystem: "yt.felix.xlr.spike", category: "host")

@MainActor
final class ExtensionController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Idle"

    func activate() { submit(.activationRequest(forExtensionWithIdentifier: driverIdentifier, queue: .main), "activate") }
    func deactivate() { submit(.deactivationRequest(forExtensionWithIdentifier: driverIdentifier, queue: .main), "deactivate") }

    private func submit(_ request: OSSystemExtensionRequest, _ verb: String) {
        report("Requesting \(verb) of \(driverIdentifier)")
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func report(_ message: String) {
        status = message
        log.notice("XLRSpike: \(message, privacy: .public)")
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        log.notice("XLRSpike: replacing \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.report("Needs approval in System Settings → General → Login Items & Extensions → Driver Extensions") }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let text = result == .completed ? "completed" : "will complete after reboot"
        Task { @MainActor in self.report("Request finished: \(text)") }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        Task { @MainActor in self.report("Request failed: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)") }
    }
}

@main
struct SpikeHostApp: App {
    @StateObject private var controller = ExtensionController()

    var body: some Scene {
        WindowGroup("XLR Signing Spike") {
            VStack(alignment: .leading, spacing: 12) {
                Text(controller.status).textSelection(.enabled)
                HStack {
                    Button("Activate driver") { controller.activate() }
                    Button("Deactivate driver") { controller.deactivate() }
                }
            }
            .padding()
            .frame(minWidth: 460)
            .task {
                let args = CommandLine.arguments
                if args.contains("--activate") { controller.activate() }
                if args.contains("--deactivate") { controller.deactivate() }
            }
        }
    }
}
