import Foundation
import Combine
import Network

/// A local route check, not a promise that a peer is reachable or permission granted.
@MainActor
final class TransportAvailability: ObservableObject {
    @Published private(set) var wifiMessage = "Checking Wi-Fi availability…"
    @Published private(set) var wifiAvailable = false
    private var monitors: [NWPathMonitor] = []
    func start() {
        guard monitors.isEmpty else { return }
        for type in [NWInterface.InterfaceType.wifi] {
            let monitor = NWPathMonitor(requiredInterfaceType: type)
            monitors.append(monitor)
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in
                    guard let self else { return }
                    let available = path.status == .satisfied
                    if type == .wifi {
                        self.wifiAvailable = available
                        self.wifiMessage = available ? "Wi-Fi is available." : "Wi-Fi is unavailable on this iPad. Enable Wi-Fi and join a network in Settings → Wi-Fi."

                    }
                }
            }
            monitor.start(queue: .main)
        }
    }
}
