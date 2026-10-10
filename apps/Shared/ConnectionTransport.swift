import Foundation
import Network

/// Selection controls routing, never the gesture or application contract.
enum ConnectionTransport: String, CaseIterable, Identifiable {
    case wired, wifi, bluetooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth LE"
        case .wired: "Wired"
        }
    }
    var instructions: String {
        switch self {
        case .wifi: "Keep both devices on the same Wi-Fi. Guest networks may block device connections."
        case .bluetooth: "Enable Bluetooth pairing on the Mac, select it here and paste its pairing key. Wi-Fi is not needed."
        case .wired: "Connect the iPad directly to your Mac with a USB-C cable. Select the Mac and connect; no key or security code is needed."
        }
    }
    func configure(_ parameters: NWParameters) {
        switch self {
        case .wifi: parameters.requiredInterfaceType = .wifi
        case .wired:
            // USB NCM routes are not consistently classified as wiredEthernet.
            // Discovery supplies the exact interface; never permit a radio fallback.
            parameters.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
        case .bluetooth: break // TLS uses a loopback byte relay over BLE.
        }
    }
}
