// camshot: still photos from a camera, for hardware sessions where the result is
// visual (button LEDs). Takes a photo only when run; never streams or records.
// Photos belong in ~/dev/goxlr-re/hardware-logs/, never in the repo.
//
//   camshot list
//   camshot capture <out.jpg> [--camera <name substring>] [--count N] [--interval ms]
//
// With --count N it takes N photos (out-1.jpg ... out-N.jpg) --interval ms apart,
// for things that change over time (flashing).
//
// Build and run with build.sh. It is a small app bundle launched through `open`,
// so macOS asks the user about camshot itself: a tool started from an agent's
// shell inherits that host's camera policy, which may forbid the prompt.

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("camshot: \(message)\n".utf8))
    exit(1)
}

func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

func cameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                     mediaType: .video, position: .unspecified).devices
}

func requireAccess() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return
    case .notDetermined:
        let done = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { granted = $0; done.signal() }
        done.wait()
        if !granted { fail("camera access was declined") }
    default:
        fail("camera access is off for this app; allow it in System Settings → Privacy & Security → Camera")
    }
}

final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private(set) var frames = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = buffer; frames += 1; lock.unlock()
    }

    func current() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}

func save(_ buffer: CVPixelBuffer, to path: String) {
    let image = CIImage(cvPixelBuffer: buffer)
    guard let cgImage = CIContext().createCGImage(image, from: image.extent),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            UTType.jpeg.identifier as CFString, 1, nil) else {
        fail("can't encode \(path)")
    }
    CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(path)") }
}

func capture(to path: String) {
    requireAccess()
    let all = cameras()
    let wanted = value(after: "--camera")
    guard let camera = wanted.map({ name in all.first { $0.localizedName.localizedCaseInsensitiveContains(name) } }) ?? all.first
    else { fail(wanted.map { "no camera matching \"\($0)\"" } ?? "no camera found") }
    let count = max(1, value(after: "--count").flatMap(Int.init) ?? 1)
    let interval = Double(value(after: "--interval").flatMap(Int.init) ?? 500) / 1000

    let session = AVCaptureSession()
    session.sessionPreset = .high
    guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
        fail("can't open \(camera.localizedName)")
    }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let grabber = FrameGrabber()
    output.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "frames"))
    guard session.canAddOutput(output) else { fail("can't read frames from \(camera.localizedName)") }
    session.addOutput(output)
    session.startRunning()
    defer { session.stopRunning() }

    // Wait for frames (a camera can take seconds to start), then let exposure
    // and white balance settle before the first photo.
    let started = Date()
    while grabber.frames == 0 && Date().timeIntervalSince(started) < 8 { Thread.sleep(forTimeInterval: 0.1) }
    Thread.sleep(forTimeInterval: 1.5)
    let base = (path as NSString).deletingPathExtension, ext = (path as NSString).pathExtension
    for shot in 1...count {
        guard let frame = grabber.current() else { fail("no frames from \(camera.localizedName)") }
        let file = count == 1 ? path : "\(base)-\(shot).\(ext.isEmpty ? "jpg" : ext)"
        save(frame, to: file)
        print("\(camera.localizedName): \(file)")
        if shot < count { Thread.sleep(forTimeInterval: interval) }
    }
}

switch arguments.first {
case "list":
    for camera in cameras() { print("\(camera.localizedName) (\(camera.deviceType.rawValue))") }
case "capture" where arguments.count >= 2:
    capture(to: arguments[1])
default:
    print("usage: camshot list | capture <out.jpg> [--camera <name>] [--count N] [--interval ms]")
    exit(2)
}
