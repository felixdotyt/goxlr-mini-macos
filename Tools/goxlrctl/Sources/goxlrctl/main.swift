// goxlrctl: the XLR driver from the command line (PROMPT.md Phase 4 step 4).
//
//   goxlrctl info [--simulate]                 driver state, versions, serial
//   goxlrctl watch [--seconds N] [--simulate]  live button, fader and encoder events
//   goxlrctl read <category> <index>           one read command (hex category, e.g. 0x80C)
//   goxlrctl write <category> <index> <hex>    one write; the driver allows only its tier's writes
//   goxlrctl driver activate|deactivate|status|reset   (reset: re-attach the device; no power cut)
//
// The serial is device identity: it is printed, never written to a file.

import Foundation
import GoXLRKit

let helperPath = DriverClient.helperPath
// Line-buffer output so `watch` into a file shows events as they arrive.
setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let simulate = arguments.contains("--simulate")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("goxlrctl: \(message)\n".utf8))
    exit(1)
}

func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

func number(_ text: String) -> UInt32? {
    text.lowercased().hasPrefix("0x") ? UInt32(text.dropFirst(2), radix: 16) : UInt32(text)
}

func openDevice() -> XLRDevice {
    if simulate { return Simulator() }
    do { return try DriverClient() } catch { fail("\(error)") }
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

func describe(_ state: InputState) -> String {
    "buttons \(state.pressed.isEmpty ? "-" : state.pressed.map(String.init).joined(separator: ","))  "
        + "faders \(state.faders.map(String.init).joined(separator: " "))  "
        + "encoders \(state.encoders.map(String.init).joined(separator: " "))"
}

func info() {
    let device = openDevice()
    defer { device.close() }
    do {
        let info = try device.info()
        print("driver:   v\(info.driverVersion) (ABI \(info.abiVersion))\(simulate ? ", simulated" : "")")
        print("state:    \(info.state.map { "\($0)" } ?? "?")"
              + (info.state == .failed ? " at \(info.startFailure.map { "\($0)" } ?? "?") (0x\(String(info.failureReturn, radix: 16)))" : "")
              + (info.state == .failed ? info.startError.map { ": \($0)" } ?? "" : ""))
        print("model:    \(info.model.map { "\($0)" } ?? "?")")
        guard info.state == .ready else { return }
        print("DCP:      version \(info.dcpVersion), max payload \(info.maxPayload)")
        if let versions = info.versions {
            print("firmware: \(versions.firmwareText)")
            print("DICE:     \(versions.diceVersion.map(String.init).joined(separator: ".")) build \(versions.diceBuild), FPGA count \(versions.fpgaCount)")
        }
        switch try device.serial() {
        case .success(let serial): print("serial:   \(serial)")
        case .failure(let failure): print("serial:   \(failure)")
        }
        if let driver = device as? DriverClient, let owner = try? driver.streamOwner() {
            print("audio:    \(owner == 1 ? "streamed by Apple's driver (ADR 0004)" : "owner \(owner)")")
        }
        if let driver = device as? DriverClient, let trusted = try? driver.isTrusted() {
            print("client:   \(trusted ? "trusted (signed by the driver's team)" : "not trusted: hardware-risk commands (phantom power) are refused")")
        }
        let tiers = ["reads only", "LEDs and colours", "fader assignment and volumes", "mute", "routing", "mic", "EQ and dynamics",
                     "effects", "scribble strips", "submixes"]
        print("writes:   up to tier \(info.writeTier) (\(info.writeTier < tiers.count ? tiers[Int(info.writeTier)] : "?"))")
        print("polling:  every \(info.pollIntervalMs) ms; \(info.polls) polls, \(info.pollFailures) failed")
        print("commands: \(info.commandsSent) sent, \(info.commandsRejected) rejected, \(info.commandsFailed) failed; \(info.events) events")
    } catch {
        fail("\(error)")
    }
}

func watch() {
    let seconds = value(after: "--seconds").flatMap(Double.init)
    let queue = DispatchQueue(label: "watch")
    var events = 0, disconnects = 0
    let start = Date()
    func show(_ event: DriverEvent) {
        events += 1
        switch event {
        case .inputState(let sequence, let state): print("\(timestamp()) #\(sequence) \(describe(state))")
        case .driverState(let sequence, let state, let failure):
            print("\(timestamp()) #\(sequence) driver \(state.map { "\($0)" } ?? "?")"
                  + (state == .failed ? " at \(failure.map { "\($0)" } ?? "?")" : ""))
        case .disconnected:
            disconnects += 1
            print("\(timestamp()) driver disconnected; waiting for it to return")
        }
    }
    var monitor: DriverMonitor?
    var simulator: Simulator?
    if simulate {
        let device = Simulator()
        do { try device.subscribe(queue: queue, handler: show) } catch { fail("\(error)") }
        device.startDemo()
        simulator = device
    } else {
        let watcher = DriverMonitor(queue: queue) { change in
            switch change {
            case .connected: print("\(timestamp()) connected to the driver")
            case .event(let event): show(event)
            case .failed(let error): print("\(timestamp()) \(error)")
            }
        }
        watcher.start()
        monitor = watcher
        print("\(timestamp()) waiting for the driver (Ctrl-C to stop)")
    }
    let finish = {
        queue.sync {
            print(String(format: "%@ watched %.0f s: %d events, %d disconnects", timestamp(), Date().timeIntervalSince(start),
                         events, disconnects))
            monitor?.stop()
            simulator?.close()
        }
        exit(0)
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler(handler: finish)
    interrupt.resume()
    // An explicit leeway: with the default, a 600 s watch stopped 30 s late (H2).
    let stopTimer = DispatchSource.makeTimerSource(queue: .main)
    if let seconds {
        stopTimer.schedule(wallDeadline: .now() + seconds, leeway: .milliseconds(100))
        stopTimer.setEventHandler(handler: finish)
        stopTimer.resume()
    }
    dispatchMain()
}

func read() {
    guard arguments.count >= 3, let category = number(arguments[1]), let index = number(arguments[2]) else {
        fail("usage: goxlrctl read <category> <index>")
    }
    let device = openDevice()
    defer { device.close() }
    do {
        let outcome = try device.command(category: category, index: index, payload: [])
        guard case .ok(let payload, let attempts) = outcome else { fail("\(outcome.failure ?? .badPayload)") }
        print("0x\(String(category, radix: 16)):\(index) -> \(payload.count) bytes\(attempts > 1 ? " (after a reset)" : ""): "
              + payload.map { String(format: "%02x", $0) }.joined())
    } catch {
        fail("\(error)")
    }
}

func write() {
    guard arguments.count >= 4, let category = number(arguments[1]), let index = number(arguments[2]),
          arguments[3].count % 2 == 0 else {
        fail("usage: goxlrctl write <category> <index> <payload hex>")
    }
    let text = arguments[3]
    let payload = stride(from: 0, to: text.count, by: 2).compactMap { offset -> UInt8? in
        let start = text.index(text.startIndex, offsetBy: offset)
        return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)
    }
    guard payload.count * 2 == text.count else { fail("the payload must be hex") }
    let device = openDevice()
    defer { device.close() }
    do {
        let outcome = try device.command(category: category, index: index, payload: payload)
        guard case .ok(_, let attempts) = outcome else { fail("\(outcome.failure ?? .badPayload)") }
        print("0x\(String(category, radix: 16)):\(index) <- \(payload.count) bytes: ok\(attempts > 1 ? " (after a reset)" : "")")
    } catch {
        fail("\(error)")
    }
}

func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { fail("can't run \(path): \(error)") }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

func driver() {
    switch arguments.dropFirst().first {
    case "activate", "deactivate":
        guard FileManager.default.fileExists(atPath: helperPath) else { fail("\(helperPath) isn't installed") }
        // -n: a running helper wouldn't receive the arguments.
        let (status, output) = run("/usr/bin/open", ["-n", helperPath, "--args", "--\(arguments[1])", "--quit-when-done"])
        if status != 0 { fail("open failed: \(output)") }
        print("asked the helper to \(arguments[1]) the driver; macOS may ask for approval or your password.")
        print("check with: goxlrctl driver status")
    case "reset":
        do {
            try DriverClient().reenumerate()
            print("asked the driver to reset the device; it re-attaches in a few seconds (audio drops briefly)")
        } catch {
            fail("\(error)")
        }
    case "status":
        let (_, output) = run("/usr/bin/systemextensionsctl", ["list"])
        let lines = output.split(separator: "\n").filter { $0.contains(DriverClient.bundleIdentifier) }
        print(lines.isEmpty ? "extension: not installed" : lines.map { "extension: \($0)" }.joined(separator: "\n"))
        do {
            let info = try DriverClient().info()
            print("service:   running, state \(info.state.map { "\($0)" } ?? "?")")
        } catch {
            print("service:   \(error)")
        }
    default:
        fail("usage: goxlrctl driver activate|deactivate|status|reset")
    }
}

switch arguments.first {
case "info": info()
case "watch": watch()
case "read": read()
case "write": write()
case "driver": driver()
default:
    print("usage: goxlrctl info | watch [--seconds N] | read <category> <index> | write <category> <index> <hex> | driver activate|deactivate|status  [--simulate]")
    exit(2)
}
