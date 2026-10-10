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

    func start() {
        guard browser == nil else { return }
        status = "Looking for Macs…"
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let next = NWBrowser(for: .bonjour(type: ConnectionModel.bonjourType, domain: "local."), using: parameters)
        browser = next
        next.stateUpdateHandler = { [weak self, weak next] state in
            Task { @MainActor in
                guard let self, let next, self.browser === next else { return }
                switch state {
                case .ready: self.status = "Looking for Macs on your Wi-Fi…"
                case .waiting(let error), .failed(let error):
                    self.status = "Discovery unavailable: \(error.localizedDescription). Check Local Network permission, or use QR/manual pairing."
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
                        unique[id] = DiscoveredMac(id: id, name: name, endpoint: result.endpoint)
                    }
                }
                self.macs = unique.values.sorted { $0.id < $1.id }
                self.status = self.macs.isEmpty ? "No Mac found yet. Start pairing on the Mac and check both devices are on the same Wi-Fi." : "Macs found nearby"
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
