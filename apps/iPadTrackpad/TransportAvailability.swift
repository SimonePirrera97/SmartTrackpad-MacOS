import Foundation
import Combine
import Network

/// A local route check, not a promise that a peer is reachable or permission granted.
@MainActor
final class TransportAvailability: ObservableObject {
    @Published private(set) var wifiMessage = "Checking Wi-Fi availability…"
    @Published private(set) var wifiAvailable = false
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let next = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor = next
        next.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.wifiAvailable = path.status == .satisfied
                self.wifiMessage = self.wifiAvailable ? "Wi-Fi is available."
                    : "Wi-Fi is unavailable on this iPad. Enable Wi-Fi and join a network in Settings → Wi-Fi."
            }
        }
        next.start(queue: .main)
    }
}
