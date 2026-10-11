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
        case .wired: "Plug the iPad into your Mac with a USB-C cable. It connects by itself: nothing to select, no key, no code."
        }
    }
    func configure(_ parameters: NWParameters) {
        switch self {
        case .wifi: parameters.requiredInterfaceType = .wifi
        case .wired: break // A USB byte stream; see USBMux.
        case .bluetooth: break // TLS uses a loopback byte relay over BLE.
        }
    }
}
