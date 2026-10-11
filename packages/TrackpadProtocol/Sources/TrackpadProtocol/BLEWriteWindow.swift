import Foundation

/// Language-neutral framing for the optional reliable BLE command channel.
/// Packets/acks: nonzero u64 token + u32 sequence, big endian. Ack sequence is
/// the next expected packet. Only ordered bytes reach TLS; gaps and duplicates
/// never modify its stream. Window/backoff are bounded and never drop bytes.
struct BLEWriteWindow {
    static let headerSize = 12
    static let capacity = 8
    private struct Pending { let sequence: UInt32; let bytes: Data; var sentAt: Double }
    private let token: UInt64
    private var nextSequence: UInt32 = 0
    private var pending: [Pending] = []
    private var source = Data()
    private var sourceOffset = 0
    private(set) var retransmissions: UInt64 = 0
    private(set) var sentFrames: UInt64 = 0
    private(set) var maximumAckMilliseconds = 0.0
    var idle: Bool { sourceOffset == source.count && pending.isEmpty }
    var count: Int { pending.count }

    init(token: UInt64) { precondition(token != 0); self.token = token; pending.reserveCapacity(Self.capacity) }
    mutating func enqueue(_ bytes: Data) throws {
        guard idle, !bytes.isEmpty, bytes.count <= 4096 else { throw WireError.invalidMessage }
        source = bytes; sourceOffset = 0
    }
    mutating func next(at time: Double, payloadLimit: Int) throws -> Data? {
        guard time.isFinite, payloadLimit > 0 else { throw WireError.invalidMessage }
        if let index = pending.firstIndex(where: { time - $0.sentAt >= 0.25 }) {
            pending[index].sentAt = time; retransmissions += 1
            return pending[index].bytes
        }
        guard pending.count < Self.capacity, sourceOffset < source.count else { return nil }
        guard nextSequence < UInt32.max else { throw WireError.invalidMessage }
        let end = min(source.count, sourceOffset + payloadLimit)
        var packet = Data(capacity: Self.headerSize + end - sourceOffset)
        CompactInputPacket.put(token, bytes: 8, into: &packet)
        CompactInputPacket.put(UInt64(nextSequence), bytes: 4, into: &packet)
        packet.append(source[source.startIndex + sourceOffset..<source.startIndex + end])
        pending.append(Pending(sequence: nextSequence, bytes: packet, sentAt: time))
        sourceOffset = end; nextSequence += 1; sentFrames += 1
        return packet
    }
    mutating func acknowledge(_ data: Data, at time: Double) throws {
        guard data.count == Self.headerSize else { throw WireError.invalidMessage }
        var reader = BinaryReader(data: data)
        let receivedToken = try reader.uint(8), next = try reader.uint(4)
        guard receivedToken == token else { return } // Late acknowledgment from a previous connection.
        guard next <= UInt64(nextSequence) else { throw WireError.invalidMessage }
        if let oldest = pending.first, next > oldest.sequence {
            maximumAckMilliseconds = max(maximumAckMilliseconds, (time - oldest.sentAt) * 1000)
        }
        pending.removeAll { UInt64($0.sequence) < next }
        if idle { source.removeAll(keepingCapacity: true); sourceOffset = 0 }
    }
}

struct BLEWriteReceiver {
    private var token: UInt64?
    private var expected: UInt32 = 0
    mutating func accept(_ packet: Data) throws -> (bytes: Data?, acknowledgment: Data) {
        guard packet.count > BLEWriteWindow.headerSize, packet.count <= 4096 else { throw WireError.invalidMessage }
        var reader = BinaryReader(data: packet)
        let receivedToken = try reader.uint(8), sequence = try reader.uint(4)
        guard receivedToken != 0 else { throw WireError.invalidMessage }
        if token == nil {
            token = receivedToken
        }
        guard receivedToken == token else { throw WireError.invalidMessage }
        var bytes: Data?
        if sequence == expected {
            guard expected < UInt32.max else { throw WireError.invalidMessage }
            bytes = Data(packet.dropFirst(BLEWriteWindow.headerSize)); expected += 1
        }
        var ack = Data(capacity: BLEWriteWindow.headerSize)
        CompactInputPacket.put(receivedToken, bytes: 8, into: &ack)
        CompactInputPacket.put(UInt64(expected), bytes: 4, into: &ack)
        return (bytes, ack)
    }
}
