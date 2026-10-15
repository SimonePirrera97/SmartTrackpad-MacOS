#if os(macOS)
import Foundation
import Combine
import Network
import Darwin
import IOKit

/// USB byte-stream adapter: a board's CDC serial port, or a cabled iPad reached
/// through USBMux. It relays the direct session byte stream to a loopback socket.
@MainActor
final class USBSerialTransport: ObservableObject {
    @Published private(set) var ports: [String] = []
    @Published private(set) var status = "USB is closed"
    private var name = "USB"
    @Published private(set) var opened = false
    var onFailure: ((String) -> Void)?
    private var generation = UUID()
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var relay: StreamByteRelay?
    private var pending = Data()
    private var completion: (() -> Void)?
    private var uartProbe: Task<Void, Never>?
    private var awaitingUART = false
    var sessionReady: Bool { opened && !awaitingUART }
    private var greeting = Data()
    private static let uartReady = Data("STPAD-UART/1!\n".utf8)

    /// Only probe CH343 bridges, then require the firmware's explicit greeting.
    static var uartPorts: [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [String] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("idVendor") as? NSNumber)?.intValue == 0x1A86,
                  (property("idProduct") as? NSNumber)?.intValue == 0x55D3,
                  let serial = property("USB Serial Number") as? String, !serial.isEmpty else { continue }
            result += names.filter { $0.hasPrefix("cu.usbmodem" + serial) || $0.hasPrefix("cu.usbserial-" + serial) }.map { "/dev/" + $0 }
        }
        return result.sorted()
    }

    /// The dedicated board names itself through its USB serial number, which
    /// macOS puts in the device name, so it is found without a port picker.
    static var boardPort: String? {
        let native = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodemSmartTrackpad") }.sorted().first.map { "/dev/" + $0 }
        return native ?? uartPorts.first
    }

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
        let uart = Self.uartPorts.contains(path)
        cfsetspeed(&attributes, speed_t(uart ? B230400 : B115200))
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
        attributes.c_cflag &= ~tcflag_t(HUPCL | CRTSCTS)
        guard tcsetattr(fd, TCSANOW, &attributes) == 0 else { Darwin.close(fd); status = "Cannot configure USB port"; return }
        relay(descriptor: fd, name: uart ? "Board UART USB" : "Board USB", targetPort: targetPort, uartHandshake: uart)
        status = uart ? "Board UART USB · identifying firmware" : "Board USB open · waiting for board session"
    }

    private func probeUART() {
        awaitingUART = true
        let currentGeneration = generation
        uartProbe = Task { [weak self] in
            for _ in 0..<20 {
                guard let self, self.generation == currentGeneration, self.awaitingUART else { return }
                if self.pending.isEmpty {
                    self.pending = Data("STPAD-UART/1?\n".utf8)
                    self.flush()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, self.generation == currentGeneration, self.awaitingUART else { return }
            self.fail("No Smart Trackpad response on UART · choose USB on the board")
        }
    }

    /// Takes ownership of an open, non-blocking descriptor.
    func relay(descriptor fd: Int32, name: String, targetPort: UInt16, uartHandshake: Bool = false) {
        stop()
        self.name = name
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
        if !uartHandshake { next.start() }
        status = "\(name) open"
        if uartHandshake { probeUART() }
    }

    func stop() {
        uartProbe?.cancel(); uartProbe = nil
        awaitingUART = false; greeting = Data()
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
        status = "\(name) is closed"
    }

    private func fail(_ reason: String) { stop(); status = reason; onFailure?(reason) }
    private func readAvailable(fd: Int32) {
        guard descriptor == fd else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count > 0 {
            let data = Data(bytes.prefix(count))
            if awaitingUART {
                greeting.append(data)
                if let range = greeting.range(of: Self.uartReady) {
                    let remaining = Data(greeting[range.upperBound...])
                    awaitingUART = false; greeting = Data()
                    uartProbe?.cancel(); uartProbe = nil
                    status = "Board UART USB · 230400 baud"
                    relay?.start()
                    if !remaining.isEmpty { relay?.accept(remaining) }
                } else if greeting.count > 4096 {
                    greeting = Data(greeting.suffix(Self.uartReady.count - 1))
                }
            } else { relay?.accept(data) }
        }
        else if count == 0 || (errno != EAGAIN && errno != EINTR) { fail("\(name) disconnected") }
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
            } else { fail("\(name) write failed"); return }
        }
        writer?.cancel(); writer = nil
        let done = completion; completion = nil; done?()
    }
}
#endif
