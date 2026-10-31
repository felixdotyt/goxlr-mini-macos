// A simulated GoXLR Mini behind the driver's interface, for tests and for
// goxlrctl without hardware. It models a tier-6 driver: reads answer, the
// lighting, volume, mute, routing, mic and effect writes (tiers 1-6) are
// accepted, other writes are refused as writesDisabled, and categories outside
// SPEC.md section 8 as opcode. It does not model the full command policy (that is the dext's,
// tested against Tests/Vectors/policy.json).

import Foundation

public final class Simulator: XLRDevice {
    /// Synthetic values, not read from a device.
    public static let versionsReply: [UInt8] = [0x00, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                                0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x30, 0x30, 0x00]
    public static let serialReply: [UInt8] = Array("SIMULATED0000".utf8) + [UInt8](repeating: 0, count: 35)

    private static let readCommands: Set<UInt64> = [0x800 << 12, 0x80C << 12, 0x80F << 12, 0x80F << 12 | 1]
    private static let allowedWrites: Set<UInt32> = [0x803, 0x808, 0x814, 0x816, 0x805, 0x806, 0x809, 0x804, 0x80B, 0x801]
    private static let knownCategories: Set<UInt32> = [0x800, 0x801, 0x802, 0x803, 0x804, 0x805, 0x806, 0x808, 0x809,
                                                       0x80A, 0x80B, 0x80C, 0x80F, 0x811, 0x814, 0x816, 0x817, 0x818]

    private let lock = NSLock()
    private var state = InputState(buttons: 0, encoders: [0, 0, 0, 0], faders: [0, 64, 128, 255])
    private var sequence: UInt64 = 0
    private var commands: UInt64 = 0
    private var rejected: UInt64 = 0
    private var subscriber: (queue: DispatchQueue, handler: (DriverEvent) -> Void)?
    private var timer: DispatchSourceTimer?

    public init() {}

    public func info() throws -> DriverInfo {
        lock.lock(); defer { lock.unlock() }
        var raw = [UInt8]()
        for value: UInt32 in [5, 10, DriverState.ready.rawValue, StartFailure.none.rawValue, 0, 0, 0, DeviceModel.mini.rawValue,
                              2, 1024, 1, 3, 0, 0] { raw.appendLE(value) }
        raw += Self.versionsReply
        for value: UInt32 in [6, 20] { raw.appendLE(value) }
        for value: UInt64 in [commands, rejected, 0, 0, 0, sequence] { raw.appendLE(value) }
        guard let info = DriverInfo(raw) else { throw DriverClientError.badReply }
        return info
    }

    public func command(category: UInt32, index: UInt32, payload: [UInt8]) throws -> CommandOutcome {
        lock.lock(); defer { lock.unlock() }
        guard Self.knownCategories.contains(category) else {
            rejected += 1
            return .rejected(.opcode)
        }
        if Self.allowedWrites.contains(category), !payload.isEmpty {
            commands += 1
            return .ok(payload: [], attempts: 1)
        }
        guard Self.readCommands.contains(UInt64(category) << 12 | UInt64(index)), payload.isEmpty else {
            rejected += 1
            return .rejected(.writesDisabled)
        }
        commands += 1
        switch (category, index) {
        case (0x800, 0): return .ok(payload: state.bytes, attempts: 1)
        case (0x80C, 0): return .ok(payload: [0, 0], attempts: 1)
        case (0x80F, 0): return .ok(payload: Self.versionsReply, attempts: 1)
        default: return .ok(payload: Self.serialReply, attempts: 1)
        }
    }

    public func subscribe(queue: DispatchQueue, handler: @escaping (DriverEvent) -> Void) throws {
        lock.lock()
        subscriber = (queue, handler)
        let current = state
        sequence += 1
        let first = sequence
        lock.unlock()
        queue.async {
            handler(.driverState(sequence: first, .ready, StartFailure.none))
            handler(.inputState(sequence: first, current))
        }
    }

    /// Replaces the input state, as a button press or fader move would, and sends the event.
    public func setInputState(_ newState: InputState) {
        lock.lock()
        guard newState != state else { lock.unlock(); return }
        state = newState
        sequence += 1
        let event = DriverEvent.inputState(sequence: sequence, newState)
        let target = subscriber
        lock.unlock()
        target.map { target in target.queue.async { target.handler(event) } }
    }

    /// Moves fader A back and forth every `interval`, for demos of `goxlrctl watch --simulate`.
    public func startDemo(interval: DispatchTimeInterval = .milliseconds(200)) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "simulator"))
        var step = 0
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            step += 1
            lock.lock()
            var next = state
            lock.unlock()
            next.faders[0] = UInt8((step * 16) % 256)
            next.buttons = step % 10 == 0 ? next.buttons ^ 1 << 4 : next.buttons
            setInputState(next)
        }
        timer.resume()
        self.timer = timer
    }

    public func close() {
        timer?.cancel()
        timer = nil
        lock.lock(); subscriber = nil; lock.unlock()
    }
}
