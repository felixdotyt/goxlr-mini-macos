// ControlProbe: Core Audio client for the Phase 4 step 0 control-channel spike
// (ADR 0003). Talks to the ControlSpike dext only through the HAL.
//
// Usage:
//   ControlProbe list                  plug-ins, boxes and devices with custom properties
//   ControlProbe find                  how the driver object can be found
//   ControlProbe info                  read 'xinf'
//   ControlProbe echo                  write echo commands (data, string, number), read 'xrep'
//   ControlProbe reject                write commands the dext refuses
//   ControlProbe events <n> <us>       ask for n events every <us> µs, measure delivery
//   ControlProbe device                ask the dext to publish a device with no streams (v4 only)
//   ControlProbe read <sel> [qual]     size and value of one driver property, with an optional CFString qualifier
//   ControlProbe readbin <sel> <qual>  the same, but the qualifier is sent as IOKit binary-serialized bytes
//   ControlProbe exit                  ask the dext to stop so the kernel starts the newest installed version
//
// Build: swiftc -O -o ControlProbe ControlProbe.swift

import CoreAudio
import Darwin
import Foundation
import IOKit

let dextBundleID = "yt.felix.xlr.spike.driver"

func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

func fourCCText(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? "'" + String(decoding: bytes, as: UTF8.self) + "'" : String(format: "0x%08x", value)
}

let kInfo = fourCC("xinf"), kCommand = fourCC("xcmd"), kReply = fourCC("xrep"), kEvents = fourCC("xevt"), kDeviceInfo = fourCC("xdev")

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func status(_ code: OSStatus) -> String { code == 0 ? "ok" : "\(code) (\(fourCCText(UInt32(bitPattern: code))))" }

func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _: T.Type) -> [T] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer) == 0 else { return [] }
    return Array(UnsafeBufferPointer(start: buffer.bindMemory(to: T.self, capacity: count), count: Int(size) / MemoryLayout<T>.stride))
}

func getValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == 0 ? value : nil
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == 0 else { return nil }
    return value?.takeRetainedValue() as String?
}

func getPlist(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> (OSStatus, CFPropertyList?) {
    var addr = address(selector)
    var value: Unmanaged<CFPropertyList>?
    var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
    let code = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return (code, value?.takeRetainedValue())
}

// Reads any CF-typed property, with an optional CFString qualifier, and reports the size query too.
func readQualified(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: String?) -> String {
    var addr = address(selector)
    var qualifierRef: CFString? = qualifier.map { $0 as CFString }
    let qualifierSize = qualifier == nil ? 0 : UInt32(MemoryLayout<CFString>.size)
    var size: UInt32 = 0
    let sizeCode = withUnsafeMutablePointer(to: &qualifierRef) {
        AudioObjectGetPropertyDataSize(object, &addr, qualifierSize, qualifier == nil ? nil : UnsafeRawPointer($0), &size)
    }
    var value: Unmanaged<CFTypeRef>?
    var valueSize = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
    let code = withUnsafeMutablePointer(to: &qualifierRef) {
        AudioObjectGetPropertyData(object, &addr, qualifierSize, qualifier == nil ? nil : UnsafeRawPointer($0), &valueSize, &value)
    }
    let described = value.map { describe($0.takeRetainedValue() as CFPropertyList) } ?? "nil"
    return "\(fourCCText(selector)) qualifier \(qualifier.map { "\"\($0)\"" } ?? "none"): size \(status(sizeCode)) \(size), get \(status(code)) \(described)"
}

// IOKit binary serialization of a value, the format DriverKit's OSSerialization reads.
func binarySerialized(_ value: CFTypeRef) -> Data? {
    IOCFSerialize(value, CFOptionFlags(kIOCFSerializeToBinary)) as Data?
}

// Reads a property passing already-serialized bytes as the qualifier, since the
// HAL forwards a CFString qualifier as its raw pointer (ADR 0003, v7).
func readSerializedQualifier(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: String) -> String {
    guard let bytes = binarySerialized(qualifier as CFString) else { return "IOCFSerialize failed" }
    var addr = address(selector)
    var size: UInt32 = 0
    var value: Unmanaged<CFTypeRef>?
    var valueSize = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
    let (sizeCode, code) = bytes.withUnsafeBytes { raw -> (OSStatus, OSStatus) in
        let sizeCode = AudioObjectGetPropertyDataSize(object, &addr, UInt32(raw.count), raw.baseAddress, &size)
        let code = AudioObjectGetPropertyData(object, &addr, UInt32(raw.count), raw.baseAddress, &valueSize, &value)
        return (sizeCode, code)
    }
    let described = value.map { describe($0.takeRetainedValue() as CFPropertyList) } ?? "nil"
    return "\(fourCCText(selector)) binary qualifier \"\(qualifier)\" (\(bytes.count) bytes \(bytes.map { String(format: "%02x", $0) }.joined())): size \(status(sizeCode)) \(size), get \(status(code)) \(described)"
}

func setPlist(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: CFPropertyList) -> OSStatus {
    var addr = address(selector)
    var ref: CFPropertyList = value
    return withUnsafePointer(to: &ref) {
        AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
    }
}

func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = address(selector)
    var settable: DarwinBoolean = false
    let code = AudioObjectIsPropertySettable(object, &addr, &settable)
    return code == 0 ? (settable.boolValue ? "settable" : "read-only") : "settable? \(status(code))"
}

// kAudioObjectPropertyCustomPropertyInfoList ('cust') lives in AudioServerPlugIn.h,
// which `import CoreAudio` doesn't expose to Swift.
let kCustomPropertyInfoList = fourCC("cust")

// Same layout as AudioServerPlugInCustomPropertyInfo.
struct CustomPropertyInfo { var selector: UInt32; var dataType: UInt32; var qualifierType: UInt32 }

func customProperties(_ object: AudioObjectID) -> [CustomPropertyInfo] {
    getArray(object, kCustomPropertyInfoList, CustomPropertyInfo.self)
}

func describe(_ value: CFPropertyList?) -> String {
    guard let value else { return "nil" }
    if let data = value as? Data { return "CFData(\(data.count) bytes: \(data.map { String(format: "%02x", $0) }.joined()))" }
    if let dict = value as? [String: Any] {
        return "{" + dict.keys.sorted().map { "\($0): \(describe(dict[$0] as CFPropertyList?))" }.joined(separator: ", ") + "}"
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID() { return "CFBoolean(\(value as! Bool))" }
    if let number = value as? NSNumber { return "CFNumber(\(number))" }
    if let text = value as? String { return "CFString(\"\(text)\")" }
    return "\(CFCopyTypeIDDescription(CFGetTypeID(value)) as String)"
}

func objectSummary(_ object: AudioObjectID) -> String {
    let classID = getValue(object, kAudioObjectPropertyClass, AudioClassID(0)).map(fourCCText) ?? "?"
    let name = getString(object, kAudioObjectPropertyName) ?? "-"
    var text = "object \(object) class \(classID) name \"\(name)\""
    if let bundle = getString(object, kAudioPlugInPropertyBundleID) { text += " bundle \(bundle)" }
    if let uid = getString(object, kAudioDevicePropertyDeviceUID) { text += " uid \(uid)" }
    let custom = customProperties(object)
    if !custom.isEmpty {
        text += "\n    custom: " + custom.map { "\(fourCCText($0.selector)) data \(fourCCText($0.dataType)) qualifier \(fourCCText($0.qualifierType)) \(isSettable(object, $0.selector))" }.joined(separator: "; ")
    }
    return text
}

// Every object the HAL reports, walking OwnedObjects from the system object.
func allObjects() -> [AudioObjectID] {
    var seen: [AudioObjectID] = [], queue = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioObjectPropertyOwnedObjects, AudioObjectID.self)
    while let object = queue.first {
        queue.removeFirst()
        if seen.contains(object) { continue }
        seen.append(object)
        queue += getArray(object, kAudioObjectPropertyOwnedObjects, AudioObjectID.self)
    }
    return seen
}

func translate(_ selector: AudioObjectPropertySelector, _ text: String) -> AudioObjectID {
    var addr = address(selector)
    var input: CFString = text as CFString
    var output = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let code = withUnsafeMutablePointer(to: &input) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &output)
    }
    return code == 0 ? output : AudioObjectID(kAudioObjectUnknown)
}

// The driver object: by bundle ID first, then any object carrying 'xinf'.
func findDriver(verbose: Bool) -> AudioObjectID? {
    let byBundle = translate(kAudioHardwarePropertyTranslateBundleIDToPlugIn, dextBundleID)
    if verbose { print("TranslateBundleIDToPlugIn(\(dextBundleID)) -> \(byBundle)") }
    if byBundle != kAudioObjectUnknown, customProperties(byBundle).contains(where: { $0.selector == kInfo }) { return byBundle }
    let carriers = allObjects().filter { customProperties($0).contains(where: { $0.selector == kInfo }) }
    if verbose { print("objects carrying 'xinf': \(carriers)") }
    return carriers.first
}

func requireDriver() -> AudioObjectID {
    guard let driver = findDriver(verbose: false) else { print("driver object not found"); exit(1) }
    return driver
}

// Writes a command and waits for the reply notification (or 2 s).
func command(_ driver: AudioObjectID, _ value: [String: Any]) {
    let replied = DispatchSemaphore(value: 0)
    var addr = address(kReply)
    let listener: AudioObjectPropertyListenerBlock = { _, _ in replied.signal() }
    AudioObjectAddPropertyListenerBlock(driver, &addr, DispatchQueue.global(), listener)
    defer { AudioObjectRemovePropertyListenerBlock(driver, &addr, DispatchQueue.global(), listener) }
    let start = mach_absolute_time()
    let code = setPlist(driver, kCommand, value as CFDictionary)
    print("set 'xcmd' \(describe(value as CFDictionary)) -> \(status(code))")
    guard code == 0 else { return }
    let notified = replied.wait(timeout: .now() + 2) == .success
    print("  reply notification: \(notified ? String(format: "%.2f ms", ms(mach_absolute_time() - start)) : "none in 2 s")")
    let (readCode, reply) = getPlist(driver, kReply)
    print("  'xrep' \(status(readCode)): \(describe(reply))")
}

var timebase = mach_timebase_info_data_t()
func ms(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

func percentile(_ sorted: [Double], _ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }

// Counts every notification, and when the value is readable also the dext's
// sequence numbers and the latency from its timestamp.
func runEvents(_ driver: AudioObjectID, count: Int, intervalUs: Int) {
    var latencies: [Double] = [], arrivals: [UInt64] = [], seqs = Set<UInt64>()
    let lock = NSLock()
    let done = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "events")
    var addr = address(kEvents)
    let listener: AudioObjectPropertyListenerBlock = { _, _ in
        let arrival = mach_absolute_time()
        let (_, value) = getPlist(driver, kEvents)
        lock.lock()
        arrivals.append(arrival)
        if let event = value as? [String: Any], let seq = (event["seq"] as? NSNumber)?.uint64Value,
           let sent = (event["t"] as? NSNumber)?.uint64Value {
            seqs.insert(seq)
            if arrival >= sent { latencies.append(ms(arrival - sent)) }
        }
        let finished = max(seqs.count, arrivals.count) >= count
        lock.unlock()
        if finished { done.signal() }
    }
    AudioObjectAddPropertyListenerBlock(driver, &addr, queue, listener)
    let start = mach_absolute_time()
    command(driver, ["op": "events", "count": count, "intervalUs": intervalUs])
    let expected = Double(count * intervalUs) / 1e6
    _ = done.wait(timeout: .now() + expected + 3)
    let elapsed = ms(mach_absolute_time() - start) / 1000
    AudioObjectRemovePropertyListenerBlock(driver, &addr, queue, listener)
    lock.lock(); defer { lock.unlock() }
    let gaps = zip(arrivals.dropFirst(), arrivals).map { ms($0 - $1) }.sorted()
    print(String(format: "events: asked %d every %d us; %d notifications in %.2f s; readable values %d", count, intervalUs,
                 arrivals.count, elapsed, seqs.count))
    print(String(format: "  gap between notifications ms: min %.3f p50 %.3f p90 %.3f p99 %.3f max %.3f",
                 gaps.first ?? .nan, percentile(gaps, 0.5), percentile(gaps, 0.9), percentile(gaps, 0.99), gaps.last ?? .nan))
    if !seqs.isEmpty {
        let sorted = latencies.sorted(), first = seqs.min()!, last = seqs.max()!
        print(String(format: "  seqs %llu-%llu, %llu missed; latency ms (dext timestamp to listener call): min %.3f p50 %.3f p90 %.3f p99 %.3f max %.3f",
                     first, last, last - first + 1 - UInt64(seqs.count), sorted.first ?? .nan, percentile(sorted, 0.5),
                     percentile(sorted, 0.9), percentile(sorted, 0.99), sorted.last ?? .nan))
    }
}

mach_timebase_info(&timebase)
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "list":
    for object in allObjects() { print(objectSummary(object)) }
case "find":
    if let driver = findDriver(verbose: true) { print("driver: " + objectSummary(driver)) } else { print("driver object not found") }
case "info":
    let driver = requireDriver()
    let (code, value) = getPlist(driver, kInfo)
    print("'xinf' \(status(code)) \(isSettable(driver, kInfo)): \(describe(value))")
    print("'xinf' write attempt -> \(status(setPlist(driver, kInfo, ["x": 1] as CFDictionary)))")
case "echo":
    let driver = requireDriver()
    command(driver, ["op": "echo", "payload": Data([0x00, 0x01, 0x02, 0xfe, 0xff])])
    command(driver, ["op": "echo", "payload": "text"])
    command(driver, ["op": "echo", "payload": 42])
    command(driver, ["op": "echo", "payload": true])
    command(driver, ["op": "echo", "payload": ["nested": Data([0xaa])]])
case "reject":
    let driver = requireDriver()
    command(driver, ["op": "reject"])
    command(driver, ["op": "nonsense"])
    command(driver, ["no-op": 1])
    print("set 'xcmd' CFString -> \(status(setPlist(driver, kCommand, "string" as CFString)))")
case "read":
    let driver = requireDriver()
    let rest = Array(args.dropFirst())
    guard let selector = rest.first else { print("usage: ControlProbe read <sel> [qualifier]"); exit(2) }
    print(readQualified(driver, fourCC(selector), qualifier: rest.dropFirst().first))
case "readbin":
    let driver = requireDriver()
    let rest = Array(args.dropFirst())
    guard rest.count == 2 else { print("usage: ControlProbe readbin <sel> <qualifier>"); exit(2) }
    print(readSerializedQualifier(driver, fourCC(rest[0]), qualifier: rest[1]))
case "serialize":
    for text in args.dropFirst() {
        print("\"\(text)\": \(binarySerialized(text as CFString).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "failed")")
    }
case "events":
    let driver = requireDriver()
    let values = args.dropFirst().compactMap { Int($0) }
    runEvents(driver, count: values.first ?? 100, intervalUs: values.dropFirst().first ?? 20000)
case "exit":
    command(requireDriver(), ["op": "exit"])
case "device":
    let driver = requireDriver()
    command(driver, ["op": "device"])
    Thread.sleep(forTimeInterval: 1)
    let device = translate(kAudioHardwarePropertyTranslateUIDToDevice, "XLRSpikeDevice")
    print("TranslateUIDToDevice(XLRSpikeDevice) -> \(device)")
    if device != kAudioObjectUnknown {
        print(objectSummary(device))
        let (code, value) = getPlist(device, kDeviceInfo)
        print("'xdev' \(status(code)): \(describe(value))")
    }
default:
    print("usage: ControlProbe list|find|info|echo|reject|read <sel> [qual]|readbin <sel> <qual>|serialize <text>...|events <n> <us>|exit|device")
    exit(2)
}
