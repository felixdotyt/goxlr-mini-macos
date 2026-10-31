// clockrate: measure a GoXLR's sample clock against the host clock (PROMPT.md Phase 2).
//
// Runs an IOProc on the GoXLR device for N seconds, writes silence and keeps
// no input audio; it records only the IOProc timestamps. It changes no
// device or system settings.
//
// Reports the device rate from a least-squares fit of sample time against
// host time, the mean HAL rate scalar, and timeline discontinuities.
//
// Usage: clockrate [seconds (default 30)]

import CoreAudio
import Foundation

let seconds = CommandLine.arguments.count >= 2 ? Double(CommandLine.arguments[1]) ?? 30 : 30

func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> [T] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

func modelUID(_ object: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyModelUID, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

let devices = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, as: AudioObjectID.self)
guard let device = devices.first(where: { modelUID($0).hasSuffix(":1220:8FE0") || modelUID($0).hasSuffix(":1220:8FE4") })
else { print("no GoXLR CoreAudio device"); exit(1) }
let nominal = read(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self).first ?? 0

final class Log {
    let capacity = 200_000
    let sample: UnsafeMutablePointer<Float64>, host: UnsafeMutablePointer<UInt64>, scalar: UnsafeMutablePointer<Float64>
    var count = 0, gaps = 0, lastEnd = -1.0
    init() {
        sample = .allocate(capacity: capacity); host = .allocate(capacity: capacity); scalar = .allocate(capacity: capacity)
    }
}
let log = Log()
var info = mach_timebase_info_data_t()
mach_timebase_info(&info)
let start = mach_absolute_time()
let stopAt = start + UInt64(seconds * 1e9 * Double(info.denom) / Double(info.numer))
let done = DispatchSemaphore(value: 0)

var procID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, outData, outTime in
    let output = UnsafeMutableAudioBufferListPointer(outData)
    var frames = 0
    for buffer in output {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        frames = Int(buffer.mDataByteSize) / max(1, Int(buffer.mNumberChannels) * 4)
    }
    let t = outTime.pointee
    if log.count < log.capacity, t.mFlags.contains(.sampleHostTimeValid) {
        if log.lastEnd >= 0 && t.mSampleTime != log.lastEnd { log.gaps += 1 }
        log.lastEnd = t.mSampleTime + Double(frames)
        log.sample[log.count] = t.mSampleTime
        log.host[log.count] = t.mHostTime
        log.scalar[log.count] = t.mFlags.contains(.rateScalarValid) ? t.mRateScalar : .nan
        log.count += 1
    }
    if mach_absolute_time() >= stopAt { done.signal() }
}
guard status == noErr, let procID else { print("AudioDeviceCreateIOProcIDWithBlock failed: \(status)"); exit(1) }
guard AudioDeviceStart(device, procID) == noErr else { print("AudioDeviceStart failed"); exit(1) }
_ = done.wait(timeout: .now() + seconds + 5)
AudioDeviceStop(device, procID)
AudioDeviceDestroyIOProcID(device, procID)

// Least squares: sample time = a + rate * host seconds.
let n = log.count
guard n > 100 else { print("too few callbacks: \(n)"); exit(1) }
let toSeconds = Double(info.numer) / Double(info.denom) / 1e9
let h0 = log.host[0], s0 = log.sample[0]
var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, scalarSum = 0.0, scalarN = 0
var scalarMin = Double.infinity, scalarMax = -Double.infinity
for i in 0..<n {
    let x = Double(log.host[i] - h0) * toSeconds, y = log.sample[i] - s0
    sx += x; sy += y; sxx += x * x; sxy += x * y
    let r = log.scalar[i]
    if !r.isNaN { scalarSum += r; scalarN += 1; scalarMin = min(scalarMin, r); scalarMax = max(scalarMax, r) }
}
let rate = (Double(n) * sxy - sx * sy) / (Double(n) * sxx - sx * sx)
let intercept = (sy - rate * sx) / Double(n)
var maxResidual = 0.0
for i in 0..<n {
    let x = Double(log.host[i] - h0) * toSeconds
    maxResidual = max(maxResidual, abs(log.sample[i] - s0 - intercept - rate * x))
}
let span = Double(log.host[n - 1] - h0) * toSeconds
print(String(format: "callbacks %d over %.2f s, buffer %.0f frames, timeline gaps %d", n, span,
             (log.sample[n - 1] - s0) / Double(n - 1), log.gaps))
print(String(format: "device rate %.4f Hz vs nominal %.0f: %+.2f ppm (fit residual max %.2f frames)",
             rate, nominal, (rate / nominal - 1) * 1e6, maxResidual))
if scalarN > 0 {
    print(String(format: "HAL rate scalar mean %.8f (%+.2f ppm), min %.8f, max %.8f",
                 scalarSum / Double(scalarN), (scalarSum / Double(scalarN) - 1) * 1e6, scalarMin, scalarMax))
}
