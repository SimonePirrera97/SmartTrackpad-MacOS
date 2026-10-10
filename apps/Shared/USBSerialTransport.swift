#if os(macOS)
import Foundation
import Combine
import Network
import Darwin

/// Board USB CDC adapter. A physical port carries the direct session byte stream, never input
/// commands directly. iPadOS has no corresponding generic USB CDC adapter.
@MainActor
final class USBSerialTransport: ObservableObject {
    @Published private(set) var ports: [String] = []
    @Published private(set) var status = "Board USB is closed"
    @Published private(set) var opened = false
    var onFailure: ((String) -> Void)?
    private var generation = UUID()
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var relay: StreamByteRelay?
    private var pending = Data()
    private var completion: (() -> Void)?

    func refresh() {
        ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .sorted().map { "/dev/" + $0 }
    }

    func start(path: String, targetPort: UInt16) {
        stop()
        refresh()
        guard ports.contains(path) else { status = "Choose a connected board USB port"; return }
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { status = "Cannot open USB port: \(String(cString: strerror(errno)))"; return }
        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { Darwin.close(fd); status = "Cannot configure USB port"; return }
        cfmakeraw(&attributes)
        cfsetspeed(&attributes, speed_t(B115200))
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(fd, TCSANOW, &attributes) == 0 else { Darwin.close(fd); status = "Cannot configure USB port"; return }
        let currentGeneration = generation
        descriptor = fd
        opened = true
        let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
        let next = StreamByteRelay(socket: socket)
        relay = next
        next.onFailure = { [weak self, weak next] reason in
            guard let self, let next, self.relay === next else { return }
            self.fail(reason)
        }
        next.onBytes = { [weak self, weak next] data, complete in
            guard let self, let next, self.relay === next else { return }
            guard self.pending.isEmpty else { self.fail("USB write overlap"); return }
            self.pending = data; self.completion = complete
            self.flush()
        }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader = readSource
        readSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration else { return }
                self.readAvailable(fd: fd)
            }
        }
        readSource.setCancelHandler { Darwin.close(fd) }
        readSource.resume()
        next.start()
        status = "Board USB open · 115200 baud · waiting for board session"
    }

    func stop() {
        generation = UUID()
        opened = false
        let oldReader = reader
        oldReader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        relay?.close(); relay = nil
        if descriptor >= 0 {
            if oldReader == nil { Darwin.close(descriptor) }
            descriptor = -1
        }
        pending = Data(); completion = nil
        status = "Board USB is closed"
    }

    private func fail(_ reason: String) { stop(); status = reason; onFailure?(reason) }
    private func readAvailable(fd: Int32) {
        guard descriptor == fd else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 { relay?.accept(Data(bytes.prefix(count))) }
        else if count == 0 || (errno != EAGAIN && errno != EINTR) { fail("Board USB disconnected") }
    }
    private func flush() {
        guard descriptor >= 0 else { return }
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { pending.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && errno == EAGAIN {
                if writer == nil {
                    let fd = descriptor
                    let currentGeneration = generation
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
                    writer = source
                    source.setEventHandler { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, self.descriptor == fd, self.generation == currentGeneration else { return }
                            self.flush()
                        }
                    }
                    source.resume()
                }
                return
            } else { fail("Board USB write failed"); return }
        }
        writer?.cancel(); writer = nil
        let done = completion; completion = nil; done?()
    }
}
#endif
