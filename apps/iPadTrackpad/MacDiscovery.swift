import Combine
import Foundation
import Network

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// Bonjour locates companions; TLS and explicit approval still authorize input.
@MainActor
final class MacDiscovery: ObservableObject {
    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var status = "Looking for Macs…"
    private var browser: NWBrowser?

    func start(transport: ConnectionTransport? = nil) {
        guard browser == nil else { return }
        status = transport == .wired ? "Looking for the Mac on the USB cable…" : "Looking for Macs…"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        transport?.configure(parameters)
        let next = NWBrowser(for: .bonjour(type: (transport == .wired ? ConnectionModel.cableBonjourType : ConnectionModel.bonjourType), domain: "local."), using: parameters)
        browser = next
        next.stateUpdateHandler = { [weak self, weak next] state in
            Task { @MainActor in
                guard let self, let next, self.browser === next else { return }
                switch state {
                case .ready: self.status = transport == .wired ? "Looking for the Mac on the USB cable…" : "Looking for Macs on Wi-Fi…"
                case .waiting(let error), .failed(let error):
                    self.status = transport == .wired ? "USB discovery unavailable: \(error.localizedDescription). Connect the cable, unlock both devices and start connections on the Mac." : "Discovery unavailable: \(error.localizedDescription). Check Local Network permission, or use QR/manual pairing."
                default: break
                }
            }
        }
        next.browseResultsChangedHandler = { [weak self, weak next] results, _ in
            Task { @MainActor in
                guard let self, let next, self.browser === next else { return }
                var unique: [String: DiscoveredMac] = [:]
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        let id = "\(name).\(type).\(domain)"
                        if transport == .wired {
                            // Interface-scoped service resolution prevents a Wi-Fi result
                            // or a generic multi-interface endpoint from entering cable mode.
                            for interface in result.interfaces where interface.type != .wifi && interface.type != .cellular && interface.type != .loopback {
                                let scopedID = id + "/" + interface.name
                                let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)
                                unique[scopedID] = DiscoveredMac(id: scopedID, name: name, endpoint: endpoint)
                            }
                        } else { unique[id] = DiscoveredMac(id: id, name: name, endpoint: result.endpoint) }
                    }
                }
                self.macs = unique.values.sorted { $0.id < $1.id }
                self.status = self.macs.isEmpty ? (transport == .wired ? "No Mac found on the cable yet. Connect the USB cable and start connections on the Mac." : "No Mac found yet. Start pairing on the Mac and check both devices are on the same selected network.") : (transport == .wired ? "Mac found on the USB cable" : "Macs found nearby")
            }
        }
        next.start(queue: .main)
    }

    func stop() {
        let old = browser
        browser = nil
        old?.cancel()
        macs = []
    }
}
