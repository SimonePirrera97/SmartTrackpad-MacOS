import AppKit
import SwiftUI

@main
struct MacTrackpadCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var delegate

    var body: some Scene {
        // A dropdown under the menu-bar icon; there is no window to manage.
        MenuBarExtra("Smart Trackpad", systemImage: "computermouse") {
            CompanionPanel(connection: delegate.service.connection, pointer: delegate.service.pointer,
                           nativePinch: delegate.service.nativePinch, navigation: delegate.service.navigation,
                           bluetooth: delegate.service.connection.bluetooth, service: delegate.service)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the service from launch, so devices connect whether or not the dropdown was ever opened.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    let service = CompanionService()
}

struct CompanionPanel: View {
    @ObservedObject var connection: ConnectionModel
    @ObservedObject var pointer: QuartzPointerBackend
    @ObservedObject var nativePinch: NativePinchBackend
    @ObservedObject var navigation: NativeNavigationBackend
    @ObservedObject var bluetooth: BluetoothTransport
    let service: CompanionService
    @StateObject private var pairingDisplay = PairingDisplayModel()

    private var invitation: String? {
        guard connection.listening, !connection.pairingKey.isEmpty else { return nil }
        return try? PairingInvitation(version: 1, host: pairingDisplay.host,
                                      port: ConnectionModel.port, key: connection.pairingKey).encoded()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func releaseAll() { pointer.releaseAll(); nativePinch.cancel(); navigation.cancel() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusSection
            Divider()
            if connection.awaitingApproval { approvalSection; Divider() }
            togglesSection
            Divider()
            devicesSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .toggleStyle(.checkbox)
        .onAppear {
            pointer.refreshPermission()
            if !LocalAddresses.ipv4.contains(pairingDisplay.host) { pairingDisplay.host = LocalAddresses.ipv4.first ?? "" }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(connection.status, systemImage: connection.connected
                  ? (connection.directCableSession ? "cable.connector" : "lock.shield.fill") : "circle.dotted")
                .font(.headline).textSelection(.enabled)
            if pointer.permissionGranted {
                Label("Accessibility approved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Label("Accessibility permission needed", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
                HStack {
                    Button("Open settings") { pointer.requestPermission() }
                    Button("Check again") { pointer.refreshPermission() }
                }
            }
        }
    }

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Approve this iPad if the code matches").font(.subheadline)
            Text(connection.pairingCode).font(.title.monospacedDigit())
            HStack {
                Button("Approve") { connection.approve() }.buttonStyle(.borderedProminent)
                Button("Decline") { connection.reject() }
            }
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Allow input control", isOn: $pointer.enabled)
            Toggle("Navigation and Show Desktop", isOn: $navigation.enabled)
            if nativePinch.available { Toggle("Pinch to zoom", isOn: $nativePinch.enabled) }
            Toggle("Scroll momentum", isOn: $pointer.momentumEnabled)
            if pointer.momentumEnabled {
                HStack {
                    Slider(value: $pointer.momentumLength, in: 0.5...2)
                    Text(String(format: "%.1f×", pointer.momentumLength)).monospacedDigit().font(.caption)
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(connection.cableStatus, systemImage: "cable.connector").font(.subheadline).foregroundStyle(.secondary)
            if connection.boardNeedsKey {
                Button("Remember this board") { connection.rememberBoard() }
                    .help("Gives the board on the cable a permanent key, so it can connect over Wi-Fi by itself.")
            }
            if connection.boardRemembered {
                HStack {
                    Label("Board remembered", systemImage: "checkmark.seal").font(.subheadline)
                    Spacer()
                    Button("Forget") { connection.forgetBoard() }
                }
            }
            if !connection.listening {
                Button("Pair an iPad over Wi-Fi or Bluetooth") { connection.startListening() }
            } else if !connection.connected {
                Toggle("Allow Bluetooth LE pairing", isOn: Binding(
                    get: { bluetooth.enabled },
                    set: { enabled in
                        if enabled { connection.enableBluetooth() }
                        else {
                            if connection.activeTransport == .bluetooth && connection.active { connection.disconnect() }
                            bluetooth.stop()
                        }
                    }))
                HStack {
                    Button("Copy pairing key") { copy(connection.pairingKey) }.buttonStyle(.borderedProminent)
                    Toggle("QR code", isOn: $pairingDisplay.showCode).toggleStyle(.button)
                }
                if pairingDisplay.showCode {
                    if LocalAddresses.ipv4.count > 1 {
                        Picker("Address", selection: $pairingDisplay.host) {
                            ForEach(LocalAddresses.ipv4, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if let payload = invitation { PairingQRCode(payload: payload) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if connection.connected { Button("Disconnect") { connection.disconnect() } }
            Menu("More") {
                Button("Release all input") { releaseAll() }
                Button("Copy diagnostics") {
                    copy(connection.diagnostics + "\nAccessibility: \(pointer.permissionGranted), input enabled: \(pointer.enabled), dragging: \(pointer.dragging), momentum: \(pointer.momentumEnabled)\nAction: \(service.actions.status)\nPinch: available \(nativePinch.available), enabled \(nativePinch.enabled), active \(nativePinch.active); \(nativePinch.status)\nNavigation: \(navigation.status); enabled \(navigation.enabled), pages \(navigation.pagesAvailable), Mission Control \(navigation.missionControlAvailable), desktop \(navigation.desktopAvailable)\nBluetooth: \(bluetooth.status)")
                }
                if connection.listening || connection.cableConnectionsEnabled {
                    Button("Stop all connections") { connection.stopListening() }
                } else {
                    Button("Start connections") { connection.startListening() }
                }
            }
            .fixedSize()
            Spacer()
            Button("Quit") {
                connection.stopListening()
                releaseAll()
                NSApplication.shared.terminate(nil)
            }.keyboardShortcut("q")
        }
    }
}
