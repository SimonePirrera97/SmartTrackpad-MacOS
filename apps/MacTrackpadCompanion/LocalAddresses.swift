import Foundation
import Darwin

enum LocalAddresses {
    static var ipv4: [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var results: [String] = []
        var current = interfaces
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                results.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return Array(Set(results)).sorted()
    }
}
