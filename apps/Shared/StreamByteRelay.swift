import Foundation
import Network

/// Main-queue socket adapter with bounded incoming storage and one send in flight.
@MainActor
final class StreamByteRelay {
    var onBytes: ((Data, @escaping () -> Void) -> Void)?
    var onFailure: ((String) -> Void)?
    private let socket: NWConnection
    private var pending = Data()
    private var sending = false
    private var ready = false
    private var closed = false
    init(socket: NWConnection) { self.socket = socket }
    func start() {
        socket.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.ready = true; self.flush(); self.read()
                case .failed(let error), .waiting(let error): self.onFailure?("Byte relay failed: \(error.localizedDescription)")
                case .cancelled: self.onFailure?("Byte relay closed")
                default: break
                }
            }
        }
        socket.start(queue: .main)
    }
    func close() { closed = true; socket.cancel(); pending = Data() }
    func accept(_ bytes: Data) {
        guard !closed else { return }
        guard pending.count + bytes.count <= 262_144 else { onFailure?("Byte relay receive buffer full"); return }
        pending.append(bytes); flush()
    }
    private func flush() {
        guard !closed, ready, !sending, !pending.isEmpty else { return }
        let bytes = Data(pending.prefix(4096)); pending.removeFirst(bytes.count)
        sending = true
        socket.send(content: bytes, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.sending = false
                if error != nil { self.onFailure?("Byte relay send failed") }
                else { self.flush() }
            }
        })
    }
    private func read() {
        guard !closed else { return }
        socket.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                guard error == nil, !complete else { self.onFailure?("Byte relay disconnected"); return }
                guard let bytes, !bytes.isEmpty else { self.read(); return }
                self.onBytes?(bytes) { [weak self] in self?.read() }
            }
        }
    }
}
