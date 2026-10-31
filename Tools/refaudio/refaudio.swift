// refaudio: reference loopback recording for a GoXLR / GoXLR Mini (PROMPT.md Phase 2).
//
// Plays one quiet sine per output channel (a distinct frequency each) and
// records every input channel at the same time, through an IOProc on the
// GoXLR device only. It changes no device or system settings: no sample
// rate, buffer size or default-device changes.
//
// Writes <out>.wav (all inputs, float32) and <out>.json (stimulus, levels,
// onset latency), and prints which output channels reach which inputs.
//
// Usage: refaudio <out-path-without-extension> [level-dBFS (default -30)]

import CoreAudio
import Foundation

// One frequency per output channel. Integer Hz, so a 1 s window is
// bin-centred; harmonics below 3.5 kHz do not land on another tone.
let toneHz: [Double] = [300, 500, 700, 1100, 1300, 1700, 1900, 2300, 2900, 3100]
let preRoll = 1.0, toneLength = 4.0, postRoll = 1.0, fade = 0.02

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: refaudio <out-path-without-extension> [level-dBFS]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = CommandLine.arguments[1]
let levelDB = CommandLine.arguments.count >= 3 ? Double(CommandLine.arguments[2]) ?? -30 : -30
guard levelDB <= -20 else { print("refusing level above -20 dBFS"); exit(2) }
let amplitude = pow(10, levelDB / 20)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as: T.Type) -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

func name(_ object: AudioObjectID, element: UInt32 = kAudioObjectPropertyElementMain,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          selector: AudioObjectPropertySelector = kAudioObjectPropertyName) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectHasProperty(object, &addr),
          AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
          let value else { return "" }
    return value.takeRetainedValue() as String
}

func streamFormat(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    guard let stream = read(device, kAudioDevicePropertyStreams, scope, as: AudioStreamID.self).first else { return nil }
    return read(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self).first
}

// Find the GoXLR by its model UID (set by Apple's USB audio driver from VID/PID).
let devices = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, as: AudioObjectID.self)
guard let device = devices.first(where: {
    let model = name($0, selector: kAudioDevicePropertyModelUID)
    return model.hasSuffix(":1220:8FE0") || model.hasSuffix(":1220:8FE4")
}) else { print("no GoXLR CoreAudio device"); exit(1) }

let rate = read(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self).first ?? 0
guard let outFormat = streamFormat(device, kAudioObjectPropertyScopeOutput),
      let inFormat = streamFormat(device, kAudioObjectPropertyScopeInput),
      outFormat.mFormatID == kAudioFormatLinearPCM, inFormat.mFormatID == kAudioFormatLinearPCM,
      outFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, inFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
      outFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, inFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
else { print("unexpected stream formats"); exit(1) }
let outChannels = Int(outFormat.mChannelsPerFrame), inChannels = Int(inFormat.mChannelsPerFrame)
guard outChannels <= toneHz.count else { print("more output channels than tones"); exit(1) }

let totalFrames = Int((preRoll + toneLength + postRoll) * rate)
let toneStart = Int(preRoll * rate), toneEnd = Int((preRoll + toneLength) * rate), fadeFrames = Int(fade * rate)

// Preallocated state, touched only by the IOProc until it stops.
final class State {
    let captured: UnsafeMutablePointer<Float>
    var outFrames = 0, inFrames = 0
    var firstOutSampleTime = -1.0, firstInSampleTime = -1.0
    var inGaps = 0, lastInSampleTime = -1.0
    init(_ count: Int) {
        captured = .allocate(capacity: count)
        captured.initialize(repeating: 0, count: count)
    }
}
let state = State(totalFrames * inChannels)
let done = DispatchSemaphore(value: 0)

var procID: AudioDeviceIOProcID?
let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, inData, inTime, outData, outTime in
    // Input: append interleaved frames.
    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    if let buffer = input.first, let data = buffer.mData, state.inFrames < totalFrames {
        let frames = Int(buffer.mDataByteSize) / (4 * inChannels)
        let time = inTime.pointee.mSampleTime
        if state.firstInSampleTime < 0 { state.firstInSampleTime = time }
        if state.lastInSampleTime >= 0 && time != state.lastInSampleTime { state.inGaps += 1 }
        state.lastInSampleTime = time + Double(frames)
        let n = min(frames, totalFrames - state.inFrames)
        (state.captured + state.inFrames * inChannels).update(from: data.assumingMemoryBound(to: Float.self), count: n * inChannels)
        state.inFrames += n
    }
    // Output: one sine per channel inside the tone window, with short fades.
    let output = UnsafeMutableAudioBufferListPointer(outData)
    if let buffer = output.first, let data = buffer.mData {
        let samples = data.assumingMemoryBound(to: Float.self)
        let frames = Int(buffer.mDataByteSize) / (4 * outChannels)
        if state.firstOutSampleTime < 0 { state.firstOutSampleTime = outTime.pointee.mSampleTime }
        for f in 0..<frames {
            let i = state.outFrames + f
            var gain = 0.0
            if i >= toneStart && i < toneEnd {
                gain = amplitude * min(1, Double(i - toneStart) / Double(fadeFrames), Double(toneEnd - i) / Double(fadeFrames))
            }
            for c in 0..<outChannels {
                samples[f * outChannels + c] = gain == 0 ? 0 : Float(gain * sin(2 * .pi * toneHz[c] * Double(i - toneStart) / rate))
            }
        }
        state.outFrames += frames
    }
    if state.inFrames >= totalFrames && state.outFrames >= totalFrames { done.signal() }
}
guard status == noErr, let procID else { print("AudioDeviceCreateIOProcIDWithBlock failed: \(status)"); exit(1) }
guard AudioDeviceStart(device, procID) == noErr else { print("AudioDeviceStart failed"); exit(1) }
let finished = done.wait(timeout: .now() + preRoll + toneLength + postRoll + 5) == .success
AudioDeviceStop(device, procID)
AudioDeviceDestroyIOProcID(device, procID)
guard finished else { print("timed out: in \(state.inFrames) out \(state.outFrames) frames"); exit(1) }

// Analysis on the middle 2 s of the tone window (input timeline).
// Onset: first input sample above half the steady peak, measured on the
// shared device sample timeline against the first tone sample sent.
let analysisStart = toneStart + Int(1.0 * rate), analysisLength = Int(2.0 * rate)
func channel(_ c: Int, _ i: Int) -> Double { Double(state.captured[i * inChannels + c]) }
func goertzelDB(_ c: Int, _ hz: Double) -> Double {
    let w = 2 * .pi * hz / rate, k = 2 * cos(w)
    var s1 = 0.0, s2 = 0.0
    for i in analysisStart..<(analysisStart + analysisLength) { let s0 = channel(c, i) + k * s1 - s2; s2 = s1; s1 = s0 }
    let power = s1 * s1 + s2 * s2 - k * s1 * s2
    let amp = 2 * sqrt(max(power, 0)) / Double(analysisLength)
    return amp > 0 ? 20 * log10(amp) : -200
}
func rmsDB(_ c: Int, _ range: Range<Int>) -> Double {
    let sum = range.reduce(0.0) { $0 + channel(c, $1) * channel(c, $1) }
    let rms = sqrt(sum / Double(range.count))
    return rms > 0 ? 20 * log10(rms) : -200
}

let inNames = (1...inChannels).map { name(device, element: UInt32($0), scope: kAudioObjectPropertyScopeInput, selector: kAudioObjectPropertyElementName) }
let outNames = (1...outChannels).map { name(device, element: UInt32($0), scope: kAudioObjectPropertyScopeOutput, selector: kAudioObjectPropertyElementName) }
let offset = state.firstInSampleTime - state.firstOutSampleTime // input frame 0 relative to output frame 0
var rows: [[String: Any]] = []
print(String(format: "level %.0f dBFS per tone; offset input-output %.0f frames; input timestamp gaps %d", levelDB, offset, state.inGaps))
print("input channel -> tones present (dBFS, threshold -70), silence RMS, onset latency")
for c in 0..<inChannels {
    var present: [[String: Any]] = []
    for (o, hz) in toneHz.prefix(outChannels).enumerated() {
        let db = goertzelDB(c, hz)
        if db > -70 { present.append(["output": o + 1, "name": outNames[o], "hz": hz, "dBFS": (db * 10).rounded() / 10]) }
    }
    let silence = rmsDB(c, 0..<Int(0.9 * rate))
    var onset: Double? = nil
    if !present.isEmpty {
        var peak = 0.0
        for i in analysisStart..<(analysisStart + analysisLength) { peak = max(peak, abs(channel(c, i))) }
        if let first = (Int(0.5 * rate)..<toneEnd).first(where: { abs(channel(c, $0)) > peak / 2 }) {
            onset = Double(first) + offset - Double(toneStart)
        }
    }
    let label = present.map { "\($0["name"]!) \($0["dBFS"]!)" }.joined(separator: ", ")
    print(String(format: "  %2d %-28@ silence %6.1f dBFS  onset %@  %@", c + 1, inNames[c] as NSString, silence,
                 onset.map { String(format: "%.0f fr", $0) } ?? "-", label.isEmpty ? "(none)" : label))
    var row: [String: Any] = ["input": c + 1, "name": inNames[c], "silence_rms_dBFS": (silence * 10).rounded() / 10, "tones": present]
    if let onset { row["onset_frames_after_first_tone_sample"] = onset }
    rows.append(row)
}

// WAV: WAVE_FORMAT_IEEE_FLOAT (3), interleaved inputs.
var wav = Data()
func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
let dataBytes = UInt32(totalFrames * inChannels * 4)
wav.append("RIFF".data(using: .ascii)!); put32(36 + dataBytes); wav.append("WAVE".data(using: .ascii)!)
wav.append("fmt ".data(using: .ascii)!); put32(16); put16(3); put16(UInt16(inChannels)); put32(UInt32(rate))
put32(UInt32(rate) * UInt32(inChannels) * 4); put16(UInt16(inChannels * 4)); put16(32)
wav.append("data".data(using: .ascii)!); put32(dataBytes)
wav.append(Data(bytes: state.captured, count: Int(dataBytes)))
try wav.write(to: URL(fileURLWithPath: outPath + ".wav"))

let report: [String: Any] = [
    "device": name(device), "model_uid": name(device, selector: kAudioDevicePropertyModelUID),
    "sample_rate": rate, "level_dBFS": levelDB, "pre_roll_s": preRoll, "tone_s": toneLength, "post_roll_s": postRoll,
    "stimulus": outNames.enumerated().map { ["output": $0.offset + 1, "name": $0.element, "hz": toneHz[$0.offset]] },
    "input_minus_output_first_sample_time": offset, "input_timestamp_gaps": state.inGaps, "inputs": rows,
]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: outPath + ".json"))
print("wrote \(outPath).wav and \(outPath).json")
