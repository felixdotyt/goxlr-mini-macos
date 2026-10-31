// caprobe: read-only CoreAudio report for GoXLR devices (PROMPT.md Phase 2).
//
// Only reads properties (AudioObjectGetPropertyData); never sets anything.
// Usage: swift caprobe.swift [name-substring]   (default "GoXLR")

import CoreAudio
import Foundation

let filter = CommandLine.arguments.dropFirst().first ?? "GoXLR"

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
    var addr = addr
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: buffer.bindMemory(to: T.self, capacity: count), count: count))
}

func scalar<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type) -> T? {
    array(object, addr, type).first
}

func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
    var addr = addr
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectHasProperty(object, &addr),
          AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
          let value else { return nil }
    return value.takeRetainedValue() as String
}

func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    return bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? "'\(String(bytes: bytes, encoding: .ascii)!)'" : String(value)
}

func describe(_ f: AudioStreamBasicDescription) -> String {
    "\(f.mSampleRate) Hz \(fourCC(f.mFormatID)) flags=0x\(String(f.mFormatFlags, radix: 16)) " +
        "ch=\(f.mChannelsPerFrame) bits=\(f.mBitsPerChannel) bytes/frame=\(f.mBytesPerFrame)"
}

let devices = array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioObjectID.self)
var found = false
for device in devices {
    let name = string(device, address(kAudioObjectPropertyName)) ?? "?"
    guard name.localizedCaseInsensitiveContains(filter) else { continue }
    found = true
    print("DEVICE \(device) \"\(name)\"")
    print("  uid: \(string(device, address(kAudioDevicePropertyDeviceUID)) ?? "?")")
    print("  model uid: \(string(device, address(kAudioDevicePropertyModelUID)) ?? "?")")
    print("  manufacturer: \(string(device, address(kAudioObjectPropertyManufacturer)) ?? "?")")
    print("  transport: \(fourCC(scalar(device, address(kAudioDevicePropertyTransportType), UInt32.self) ?? 0))")
    print("  clock domain: \(scalar(device, address(kAudioDevicePropertyClockDomain), UInt32.self).map(String.init) ?? "?")")
    print("  nominal rate: \(scalar(device, address(kAudioDevicePropertyNominalSampleRate), Float64.self).map { "\($0)" } ?? "?")")
    let ranges = array(device, address(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange.self)
    print("  available rates: \(ranges.map { $0.mMinimum == $0.mMaximum ? "\($0.mMinimum)" : "\($0.mMinimum)-\($0.mMaximum)" })")
    print("  buffer frames: \(scalar(device, address(kAudioDevicePropertyBufferFrameSize), UInt32.self).map(String.init) ?? "?")")
    let bufferRange = scalar(device, address(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange.self)
    print("  buffer frame range: \(bufferRange.map { "\($0.mMinimum)-\($0.mMaximum)" } ?? "?")")
    print("  is alive: \(scalar(device, address(kAudioDevicePropertyDeviceIsAlive), UInt32.self).map(String.init) ?? "?")")
    print("  hidden: \(scalar(device, address(kAudioDevicePropertyIsHidden), UInt32.self).map(String.init) ?? "?")")

    for (label, scope) in [("output", kAudioObjectPropertyScopeOutput), ("input", kAudioObjectPropertyScopeInput)] {
        let streams = array(device, address(kAudioDevicePropertyStreams, scope), AudioStreamID.self)
        guard !streams.isEmpty else { continue }
        print("  \(label):")
        print("    latency: \(scalar(device, address(kAudioDevicePropertyLatency, scope), UInt32.self).map(String.init) ?? "?") frames, " +
              "safety offset: \(scalar(device, address(kAudioDevicePropertySafetyOffset, scope), UInt32.self).map(String.init) ?? "?") frames")
        let stereo = array(device, address(kAudioDevicePropertyPreferredChannelsForStereo, scope), UInt32.self)
        print("    preferred stereo channels: \(stereo)")
        for stream in streams {
            let start = scalar(stream, address(kAudioStreamPropertyStartingChannel), UInt32.self) ?? 0
            let terminal = scalar(stream, address(kAudioStreamPropertyTerminalType), UInt32.self) ?? 0
            print("    stream \(stream) starting channel \(start) terminal \(fourCC(terminal))")
            if let virtualFormat = scalar(stream, address(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription.self) {
                print("      virtual: \(describe(virtualFormat))")
            }
            if let physical = scalar(stream, address(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription.self) {
                print("      physical: \(describe(physical))")
            }
            for available in array(stream, address(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self) {
                print("      available physical: \(describe(available.mFormat)) range \(available.mSampleRateRange.mMinimum)-\(available.mSampleRateRange.mMaximum)")
            }
        }
        let channels = array(device, address(kAudioDevicePropertyStreamConfiguration, scope), UInt8.self)
        var total = 0
        if channels.count >= MemoryLayout<UInt32>.size {
            channels.withUnsafeBytes { raw in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: raw.baseAddress!.assumingMemoryBound(to: AudioBufferList.self)))
                total = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            }
        }
        print("    channels: \(total)")
        for channel in 1...max(total, 1) where total > 0 {
            let name = string(device, address(kAudioObjectPropertyElementName, scope, UInt32(channel))) ?? ""
            print("      \(channel): \(name)")
        }
    }
}
if !found { print("no CoreAudio device matching \"\(filter)\"") }
