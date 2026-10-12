import Foundation

/// Negotiated input.binary.v1. Session identity/version are established by the
/// JSON handshake and bound to this connection; sequence/time remain per frame.
struct CompactInputPacket: Sendable {
    static let capability = "input.binary.v1"
    static let marker: UInt8 = 0xd3
    static let maximumSize = 128
    let sequence: UInt64
    let timestamp: UInt64
    let input: InputCommand

    private static let kinds: [InputKind] = [.move, .click, .button, .scroll, .releaseAll, .stopMomentum, .action, .magnify, .pageSwipe, .missionControl, .showDesktop, .appControl]
    private static let phases: [ScrollPhase] = [.began, .changed, .ended, .cancelled]
    private static let actions: [StandardAction] = [.copy, .cut, .paste, .undo, .redo, .missionControl, .quit]
    private static let apps: [ControlApp] = [.other, .vscode, .terminal, .safari, .spotify, .finder]
    private static let appActions: [AppControlAction] = [.save, .compile, .delete, .deleteWord, .enter, .newTab, .closeTab, .playPause, .previousTrack, .nextTrack, .volumeDown, .volumeUp, .newFolder, .trash]

    func encode(into data: inout Data) throws {
        guard sequence > 0, input.valid else { throw WireError.invalidMessage }
        data.removeAll(keepingCapacity: true)
        data.append(contentsOf: [Self.marker, 1, 0, 0])
        Self.put(sequence, bytes: 8, into: &data)
        Self.put(timestamp, bytes: 8, into: &data)
        data.append(UInt8(Self.kinds.firstIndex(of: input.kind)!))
        switch input.kind {
        case .move, .scroll:
            if input.kind == .scroll { data.append(UInt8(Self.phases.firstIndex(of: input.phase!)!)) }
            try Self.putFloat(input.delta!.dx, into: &data)
            try Self.putFloat(input.delta!.dy, into: &data)
        case .click, .button:
            data.append(input.button == .left ? 0 : 1)
            data.append(input.kind == .click ? UInt8(input.count!) : (input.pressed! ? 1 : 0))
        case .action: data.append(UInt8(Self.actions.firstIndex(of: input.action!)!))
        case .magnify, .pageSwipe, .missionControl:
            data.append(UInt8(Self.phases.firstIndex(of: input.phase!)!))
            try Self.putFloat(input.kind == .magnify ? input.magnification! : input.progress!, into: &data)
        case .appControl:
            let request = input.appControl!
            data.append(UInt8(Self.apps.firstIndex(of: request.app)!))
            data.append(UInt8(Self.appActions.firstIndex(of: request.action)!))
            var uuid = UUID(uuidString: request.token)!.uuid
            withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        case .releaseAll, .stopMomentum, .showDesktop: break
        }
        if input.kind == .scroll || input.kind == .pageSwipe || input.kind == .missionControl {
            let flags: UInt8 = (input.sampleTimestampMilliseconds == nil ? 0 : 1) | (input.sampleIntervalMilliseconds == nil ? 0 : 2)
            data.append(flags)
            if let sample = input.sampleTimestampMilliseconds {
                guard sample <= timestamp, timestamp - sample <= UInt32.max else { throw WireError.invalidMessage }
                Self.put(timestamp - sample, bytes: 4, into: &data)
            }
            if let interval = input.sampleIntervalMilliseconds {
                guard Float(interval) > 0 else { throw WireError.invalidMessage }
                try Self.putFloat(interval, into: &data)
            }
        }
        let size = data.count
        guard size <= Self.maximumSize else { throw WireError.tooLarge }
        data[2] = UInt8(size >> 8); data[3] = UInt8(size & 255)
    }

    static func decode(_ data: Data) throws -> Self {
        var reader = BinaryReader(data: data)
        guard try reader.uint(1) == UInt64(marker), try reader.uint(1) == 1,
              try reader.uint(2) == data.count, data.count <= maximumSize else { throw WireError.invalidMessage }
        let sequence = try reader.uint(8), timestamp = try reader.uint(8)
        let kind = try reader.choice(kinds)
        var command = InputCommand(kind: kind)
        switch kind {
        case .move, .scroll:
            if kind == .scroll { command.phase = try reader.choice(phases) }
            command.delta = try PointerDelta(dx: reader.float(), dy: reader.float())
        case .click, .button:
            command.button = try reader.choice([MouseButton.left, .right])
            if kind == .click { command.count = Int(try reader.uint(1)) }
            else { command.pressed = try reader.choice([false, true]) }
        case .action: command.action = try reader.choice(actions)
        case .magnify, .pageSwipe, .missionControl:
            command.phase = try reader.choice(phases)
            let value = try reader.float()
            if kind == .magnify { command.magnification = value } else { command.progress = value }
        case .appControl:
            let app = try reader.choice(apps), action = try reader.choice(appActions)
            let bytes = try (0..<16).map { _ in UInt8(try reader.uint(1)) }
            let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            command.appControl = AppControlRequest(app: app, token: uuid.uuidString, action: action)
        case .releaseAll, .stopMomentum, .showDesktop: break
        }
        if kind == .scroll || kind == .pageSwipe || kind == .missionControl {
            let flags = try reader.uint(1)
            guard flags <= 3 else { throw WireError.invalidMessage }
            if flags & 1 != 0 {
                let age = try reader.uint(4)
                guard age <= timestamp else { throw WireError.invalidMessage }
                command.sampleTimestampMilliseconds = timestamp - age
            }
            if flags & 2 != 0 { command.sampleIntervalMilliseconds = try reader.float() }
        }
        guard reader.offset == data.count, sequence > 0, command.valid else { throw WireError.invalidMessage }
        return Self(sequence: sequence, timestamp: timestamp, input: command)
    }

    static func put(_ value: UInt64, bytes: Int, into data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) { data.append(UInt8((value >> shift) & 255)) }
    }
    private static func putFloat(_ value: Double, into data: inout Data) throws {
        let narrowed = Float(value)
        guard narrowed.isFinite else { throw WireError.invalidMessage }
        put(UInt64(narrowed.bitPattern), bytes: 4, into: &data)
    }
}

struct BinaryReader {
    let data: Data
    var offset = 0
    mutating func uint(_ bytes: Int) throws -> UInt64 {
        guard bytes > 0, bytes <= 8, offset + bytes <= data.count else { throw WireError.invalidMessage }
        var value: UInt64 = 0
        for _ in 0..<bytes { value = (value << 8) | UInt64(data[data.startIndex + offset]); offset += 1 }
        return value
    }
    mutating func float() throws -> Double { Double(Float(bitPattern: UInt32(try uint(4)))) }
    mutating func choice<T>(_ values: [T]) throws -> T {
        let index = Int(try uint(1))
        guard index < values.count else { throw WireError.invalidMessage }
        return values[index]
    }
}

struct CompactInputAcknowledgment: Sendable {
    let sequence: UInt64
    let timestamp: UInt64
    let inputSequence: UInt64
    func encode(into data: inout Data) throws {
        guard sequence > 0, inputSequence > 0 else { throw WireError.invalidMessage }
        data.removeAll(keepingCapacity: true)
        data.append(contentsOf: [CompactInputPacket.marker, 2, 0, 28])
        CompactInputPacket.put(sequence, bytes: 8, into: &data)
        CompactInputPacket.put(timestamp, bytes: 8, into: &data)
        CompactInputPacket.put(inputSequence, bytes: 8, into: &data)
    }
    static func decode(_ data: Data) throws -> Self {
        var reader = BinaryReader(data: data)
        guard data.count == 28, try reader.uint(1) == UInt64(CompactInputPacket.marker),
              try reader.uint(1) == 2, try reader.uint(2) == 28 else { throw WireError.invalidMessage }
        let sequence = try reader.uint(8), timestamp = try reader.uint(8), input = try reader.uint(8)
        guard sequence > 0, input > 0 else { throw WireError.invalidMessage }
        return Self(sequence: sequence, timestamp: timestamp, inputSequence: input)
    }
}

enum StreamPacket: Sendable { case json(WireMessage), compact(CompactInputPacket), acknowledgment(CompactInputAcknowledgment) }

/// Mixed JSON control + bounded binary input stream. Incomplete storage is at
/// most one frame. Arbitrary fragmentation and adjacent format changes work.
struct MessageFramer {
    private var buffer = Data()
    private var binarySize: Int?
    private let decoder = JSONDecoder()
    mutating func append(_ data: Data) throws -> [StreamPacket] {
        var packets: [StreamPacket] = []
        for byte in data {
            if buffer.isEmpty { binarySize = byte == CompactInputPacket.marker ? 0 : nil }
            if binarySize != nil {
                buffer.append(byte)
                if buffer.count == 4 {
                    let size = Int(buffer[buffer.startIndex + 2]) * 256 + Int(buffer[buffer.startIndex + 3])
                    let format = buffer[buffer.startIndex + 1]
                    guard (format == 1 && size >= 21 && size <= CompactInputPacket.maximumSize)
                        || (format == 2 && size == 28) else { throw WireError.invalidMessage }
                    binarySize = size
                }
                if binarySize == buffer.count {
                    if buffer[buffer.startIndex + 1] == 1 { packets.append(.compact(try CompactInputPacket.decode(buffer))) }
                    else { packets.append(.acknowledgment(try CompactInputAcknowledgment.decode(buffer))) }
                    buffer.removeAll(keepingCapacity: true); binarySize = nil
                }
            } else if byte == 10 {
                let message = try decoder.decode(WireMessage.self, from: buffer)
                try message.validate()
                packets.append(.json(message)); buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < WireMessage.maximumSize else { throw WireError.tooLarge }
                buffer.append(byte)
            }
        }
        return packets
    }
}

/// End-to-end input credits, separate from ciphertext fragment acknowledgments.
/// This lets small pointer frames share the BLE window while bounding loopback
/// backlog to eight commands, regardless of TCP kernel buffering.
struct InputAcknowledgmentWindow {
    static let capability = "input.ack.v1"
    static let capacity = 8
    private var pending: [(sequence: UInt64, time: Double)] = []
    private var lastSent: UInt64 = 0
    private var lastAcknowledged: UInt64 = 0
    var count: Int { pending.count }
    var available: Bool { count < Self.capacity }
    init() { pending.reserveCapacity(Self.capacity) }
    mutating func track(_ sequence: UInt64, at time: Double) throws {
        guard available, sequence > lastSent, time.isFinite else { throw WireError.invalidMessage }
        pending.append((sequence, time)); lastSent = sequence
    }
    mutating func acknowledge(_ sequence: UInt64, at time: Double) throws -> Double? {
        guard sequence > 0, sequence <= lastSent, time.isFinite else { throw WireError.invalidMessage }
        guard sequence > lastAcknowledged else { return nil }
        guard pending.contains(where: { $0.sequence == sequence }) else { throw WireError.invalidMessage }
        let duration = pending.first.map { max(0, time - $0.time) * 1000 }
        pending.removeAll { $0.sequence <= sequence }
        lastAcknowledged = sequence
        return duration
    }
}
