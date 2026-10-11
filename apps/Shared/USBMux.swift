#if os(macOS)
import Foundation
import Darwin

/// The system USB multiplexer: the channel Xcode and Finder use to reach a cabled
/// iPad. It carries a plain byte stream to a port the iPad app listens on, so the
/// cable needs no IP network, Bonjour or Local Network permission.
/// The protocol is undocumented but long-stable: a 16-byte little-endian header
/// (length, version 1, type 8, tag) followed by an XML property list.
enum USBMux {
    enum Probe: Sendable {
        case noDevice
        /// A cabled iPad is present but the app is not listening.
        case waiting
        /// A connected, non-blocking byte stream. The caller owns the descriptor.
        case connected(Int32)
    }

    /// Tries every USB-attached device once. Blocks briefly; call off the main actor.
    static func probe(port: UInt16) -> Probe {
        guard let list = request(["MessageType": "ListDevices"], keepOpen: false)?.reply,
              let devices = list["DeviceList"] as? [[String: Any]] else { return .noDevice }
        let cabled = devices.compactMap { device -> Int? in
            guard (device["Properties"] as? [String: Any])?["ConnectionType"] as? String == "USB" else { return nil }
            return device["DeviceID"] as? Int
        }
        for device in cabled {
            // The multiplexer expects the port in network byte order.
            guard let (reply, descriptor) = request(["MessageType": "Connect", "DeviceID": device,
                "PortNumber": Int(port.bigEndian)], keepOpen: true) else { continue }
            if reply["Number"] as? Int == 0 {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
                return .connected(descriptor)
            }
            Darwin.close(descriptor)
        }
        return cabled.isEmpty ? .noDevice : .waiting
    }

    private static func request(_ message: [String: Any], keepOpen: Bool) -> (reply: [String: Any], descriptor: Int32)? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var done = false
        defer { if !done || !keepOpen { Darwin.close(descriptor) } }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { path in
            _ = "/var/run/usbmuxd".withCString { strlcpy(path.baseAddress!.assumingMemoryBound(to: CChar.self), $0, path.count) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var fields = message
        fields["ClientVersionString"] = "SmartTrackpad"
        fields["ProgName"] = "SmartTrackpad"
        fields["kLibUSBMuxVersion"] = 3
        guard let body = try? PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0) else { return nil }
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) } }
        packet.append(body)
        guard packet.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == packet.count,
              let header = read(descriptor, count: 16) else { return nil }
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        guard length > 16, length <= 1 << 20, let payload = read(descriptor, count: length - 16),
              let reply = try? PropertyListSerialization.propertyList(from: Data(payload), format: nil) as? [String: Any] else { return nil }
        done = true
        return (reply, descriptor)
    }

    private static func read(_ descriptor: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + received, count - received) }
            if result > 0 { received += result }
            else if result < 0 && errno == EINTR { continue }
            else { return nil }
        }
        return bytes
    }
}
#endif
