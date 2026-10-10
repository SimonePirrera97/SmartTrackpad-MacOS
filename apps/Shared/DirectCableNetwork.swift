import Foundation
import Network
#if os(macOS)
import IOKit
import Darwin
#endif

/// Identifies the physical iPad USB link on Mac; ordinary Ethernet is excluded.
@MainActor
final class DirectCableNetwork {
    struct Link: Equatable {
        let name: String
        let address: String
        var id: String { name + "/" + address }
    }
    var onChange: (([Link]) -> Void)?
    private var monitoring: Task<Void, Never>?
    func start() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            var previous: [Link]?
            while !Task.isCancelled {
                #if os(macOS)
                let links = Self.attachedLinks()
                if links != previous { previous = links; self?.onChange?(links) }
                #endif
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func stop() { monitoring?.cancel(); monitoring = nil }

    #if os(macOS)
    static func attachedLinks() -> [Link] {
        let names = appleUSBInterfaceNames()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var links: [String: Link] = [:]
        var current = head
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard names.contains(name), let address = entry.pointee.ifa_addr,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Prefer scoped IPv6: its zone pins the local USB link explicitly.
            if links[name] == nil || address.pointee.sa_family == UInt8(AF_INET6) {
                links[name] = Link(name: name, address: text)
            }
        }
        return links.values.sorted { $0.id < $1.id }
    }
    #endif

    #if os(macOS)
    static func appleUSBInterfaceNames() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONetworkInterface"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let name = property(entry, "BSD Name") as? String
            var current = entry
            var eligible = false
            for _ in 0..<32 {
                let vendor = (property(current, "idVendor") as? NSNumber)?.intValue
                let product = property(current, "USB Product Name") as? String ?? ""
                if vendor == 0x05ac && (product == "iPad" || product == "iPhone") { eligible = true }
                var parent: io_registry_entry_t = 0
                let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
                IOObjectRelease(current)
                current = result == KERN_SUCCESS ? parent : 0
                if current == 0 { break }
            }
            if current != 0 { IOObjectRelease(current) }
            if eligible, let name { names.insert(name) }
        }
        return names
    }
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    #endif
}
