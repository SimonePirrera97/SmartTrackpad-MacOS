import Foundation
import Network

/// All codec state lives on one serial worker, off the UI executor. Queue order
/// matches NWConnection send order; each session gets fresh framing/codec state.
final class SessionMessageIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SmartTrackpad.session.codec", qos: .userInteractive)
    private let encoder = JSONEncoder()
    private var framer = MessageFramer()
    private var scratch = Data(capacity: CompactInputPacket.maximumSize)

    func send(_ message: WireMessage, compact: Bool, to peer: NWConnection,
              completion: @escaping @Sendable (Error?, Int) -> Void) {
        queue.async { [self] in
            do {
                let bytes: Data
                if compact, let input = message.input {
                    try message.validate()
                    try CompactInputPacket(sequence: message.sequence, timestamp: message.timestampMilliseconds, input: input).encode(into: &scratch)
                    bytes = scratch
                } else if compact, let acknowledged = message.acknowledgedInputSequence, message.appContext == nil {
                    try message.validate()
                    try CompactInputAcknowledgment(sequence: message.sequence, timestamp: message.timestampMilliseconds,
                        inputSequence: acknowledged).encode(into: &scratch)
                    bytes = scratch
                } else { bytes = try message.encoded(using: encoder) }
                let size = bytes.count
                peer.send(content: bytes, completion: .contentProcessed { error in completion(error, size) })
            } catch { completion(error, 0) }
        }
    }

    func receive(from peer: NWConnection,
                 completion: @escaping @Sendable (Result<[StreamPacket], Error>, Bool, Int) -> Void) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            queue.async { [self] in
                do {
                    let packets = try data.map { try framer.append($0) } ?? []
                    if let error { completion(.failure(error), true, data?.count ?? 0) }
                    else { completion(.success(packets), complete, data?.count ?? 0) }
                } catch { completion(.failure(error), true, data?.count ?? 0) }
            }
        }
    }
}
