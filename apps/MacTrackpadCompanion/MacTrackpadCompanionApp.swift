import AppKit
import SwiftUI

@main
struct MacTrackpadCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let service = CompanionService()
    private var statusItem: NSStatusItem?
    private var companionWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Smart Trackpad")
            button.toolTip = "Open Smart Trackpad"
            button.target = self
            button.action = #selector(showCompanionWindow)
        }
        statusItem = item
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func showCompanionWindow() {
        if companionWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Smart Trackpad Companion"
            window.contentMinSize = NSSize(width: 400, height: 360)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:
                CompanionPanel(connection: service.connection, pointer: service.pointer, actions: service.actions, nativePinch: service.nativePinch, navigation: service.navigation))
            window.center()
            companionWindow = window
        }
        companionWindow?.deminiaturize(nil)
        companionWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct CompanionPanel: View {
    @ObservedObject var connection: ConnectionModel
    @ObservedObject var pointer: QuartzPointerBackend
    @ObservedObject var actions: MacActionBackend
    @ObservedObject var nativePinch: NativePinchBackend
    @ObservedObject var navigation: NativeNavigationBackend
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Smart Trackpad", systemImage: "computermouse").font(.title2.bold())
                Label(connection.status, systemImage: connection.directCableSession ? "cable.connector" : (connection.connected ? "lock.shield.fill" : "wifi"))
                    .textSelection(.enabled)
                BoardUSBControls(connection: connection, usb: connection.boardUSB)
                BluetoothPairingControls(connection: connection, bluetooth: connection.bluetooth)
                permissionSection
                if !connection.connected { pairingSection }
                if connection.awaitingApproval { approvalSection }
                inputSection
                GroupBox("Connection details and troubleshooting") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Messages: sent \(connection.messagesSent) · received \(connection.messagesReceived)")
                            .font(.caption.monospacedDigit())
                        Text("Mac addresses").font(.subheadline.bold())
                        ForEach(LocalAddresses.ipv4, id: \.self) { address in
                            Text(address).font(.body.monospaced()).textSelection(.enabled)
                        }
                        Button("Copy diagnostics") {
                            copy(connection.diagnostics + "\nAccessibility: \(pointer.permissionGranted), input enabled: \(pointer.enabled), dragging: \(pointer.dragging), momentum: \(pointer.momentumEnabled)\nAction: \(actions.status)\nPinch: available \(nativePinch.available), enabled \(nativePinch.enabled), active \(nativePinch.active); \(nativePinch.status)\nNavigation: \(navigation.status); enabled \(navigation.enabled), pages \(navigation.pagesAvailable), Mission Control \(navigation.missionControlAvailable), desktop \(navigation.desktopAvailable)")
                        }
                        Button("Release all input") { pointer.releaseAll(); nativePinch.cancel(); navigation.cancel() }
                        if connection.listening || connection.cableConnectionsEnabled {
                            Button("Stop connections") { connection.stopListening() }
                            Text("Stopping connections disconnects the iPad. Starting again creates a new wireless pairing key.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 12)
                }
                Divider()
                HStack {
                    Text("Closing this window keeps the companion running.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") {
                        connection.stopListening()
                        pointer.releaseAll()
                        nativePinch.cancel()
                        navigation.cancel()
                        NSApplication.shared.terminate(nil)
                    }.keyboardShortcut("q")
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 400, minHeight: 360)
        .onAppear {
            pointer.refreshPermission()
            if !LocalAddresses.ipv4.contains(pairingDisplay.host) {
                pairingDisplay.host = LocalAddresses.ipv4.first ?? ""
            }
        }
    }

    private var permissionSection: some View {
        GroupBox("Input permission") {
            VStack(alignment: .leading, spacing: 12) {
                Label(pointer.permissionGranted ? "Accessibility approved" : "Accessibility permission needed",
                      systemImage: pointer.permissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle")
                Text(pointer.inputStatus).font(.subheadline).foregroundStyle(.secondary)
                if !pointer.permissionGranted {
                    Text("Allow Smart Trackpad in System Settings so the iPad can control your pointer.")
                        .font(.subheadline)
                    HStack {
                        Button("Open Accessibility settings") { pointer.requestPermission() }
                        Button("Check again") { pointer.refreshPermission() }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var pairingSection: some View {
        GroupBox("Connect your iPad") {
            VStack(alignment: .leading, spacing: 14) {
                if !connection.listening {
                    Text(connection.cableConnectionsEnabled
                        ? "An iPad on a USB cable connects by itself. Start connections here for Wi-Fi or Bluetooth LE pairing."
                        : "Start connections to accept the cable again and enable wireless pairing.")
                    Button("Start connections") { connection.startListening() }
                        .buttonStyle(.borderedProminent)
                } else if !connection.awaitingApproval {
                    Text("For Wi-Fi or Bluetooth LE, select this Mac on the iPad and paste this key. A cabled iPad needs no key.")
                    Button("Copy pairing key") { copy(connection.pairingKey) }
                        .buttonStyle(.borderedProminent)
                    Text("Then tap Connect on the iPad and approve the matching code here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Show QR code instead", isOn: $pairingDisplay.showCode)
                    if pairingDisplay.showCode {
                        Picker("Mac network address", selection: $pairingDisplay.host) {
                            ForEach(LocalAddresses.ipv4, id: \.self) { Text($0).tag($0) }
                        }
                        if let payload = invitation { PairingQRCode(payload: payload) }
                        Text("Scan from the iPad, then tap Connect.").font(.subheadline)
                    }
                    DisclosureGroup("Manual pairing alternatives") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Mac network address", selection: $pairingDisplay.host) {
                                ForEach(LocalAddresses.ipv4, id: \.self) { Text($0).tag($0) }
                            }
                            if let payload = invitation {
                                Button("Copy address and key together") { copy(payload) }
                            }
                            Text("Paste these combined details using Paste on the iPad, or enter this address and the key manually.")
                                .font(.footnote).foregroundStyle(.secondary)
                            DisclosureGroup("Show pairing key") {
                                Text(connection.pairingKey).font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }.padding(.top, 12)
                    }
                } else {
                    Text("An iPad is waiting for your approval below.")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var approvalSection: some View {
        GroupBox("Approve this iPad") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Check that this code matches the iPad before approving.")
                Text(connection.pairingCode).font(.largeTitle.monospacedDigit())
                HStack {
                    Button("Approve") { connection.approve() }.buttonStyle(.borderedProminent)
                    Button("Decline") { connection.reject() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var inputSection: some View {
        GroupBox("Input controls") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Allow input control", isOn: $pointer.enabled)
                Toggle("Navigation and Show Desktop", isOn: $navigation.enabled)
                Text(navigation.status).font(.footnote).foregroundStyle(.secondary)
                Toggle("Scroll momentum", isOn: $pointer.momentumEnabled)
                if nativePinch.available {
                    Toggle("Pinch to zoom", isOn: $nativePinch.enabled)
                    Text(nativePinch.status).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Pinch to zoom unavailable on this Mac.").font(.footnote)
                }
                if pointer.momentumEnabled {
                    HStack {
                        Text("Momentum length")
                        Slider(value: $pointer.momentumLength, in: 0.5...2)
                        Text(String(format: "%.1f×", pointer.momentumLength)).monospacedDigit()
                    }
                }
                Text("Momentum uses simulated deceleration.").font(.footnote).foregroundStyle(.secondary)
                Text(actions.status).font(.footnote).foregroundStyle(.secondary)
                HStack {
                    if connection.connected {
                        Button("Disconnect iPad") { connection.disconnect() }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}


private struct BluetoothPairingControls: View {
    @ObservedObject var connection: ConnectionModel
    @ObservedObject var bluetooth: BluetoothTransport
    var body: some View {
        GroupBox("Connection options") {
            VStack(alignment: .leading, spacing: 12) {
                Text("An iPad on a USB cable connects by itself, without pairing. Wi-Fi and Bluetooth LE use a pairing key and approval code.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(connection.cableStatus).font(.subheadline).foregroundStyle(.secondary)
                Toggle("Allow Bluetooth LE pairing", isOn: Binding(
                    get: { bluetooth.enabled },
                    set: { enabled in
                        if enabled { connection.enableBluetooth() }
                        else {
                            if connection.activeTransport == .bluetooth && connection.active { connection.disconnect() }
                            bluetooth.stop()
                        }
                    }))
                Text(bluetooth.status).font(.footnote).foregroundStyle(.secondary)
                if connection.boardNeedsKey || connection.boardRemembered {
                    Divider()
                    if connection.boardNeedsKey {
                        Button("Remember this board") { connection.rememberBoard() }
                            .buttonStyle(.borderedProminent)
                        Text("Gives the board on the cable a permanent key. It can then connect over Wi-Fi or Bluetooth by itself, without a pairing key or approval.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if connection.boardRemembered {
                        Label("Board remembered", systemImage: "checkmark.seal")
                        Text("It connects by itself over Wi-Fi or Bluetooth while this app is running.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Forget board") { connection.forgetBoard() }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}


private struct BoardUSBControls: View {
    @ObservedObject var connection: ConnectionModel
    @ObservedObject var usb: USBSerialTransport
    @State private var selectedPort = ""
    var body: some View {
        DisclosureGroup("Dedicated board USB (manual)") {
            VStack(alignment: .leading, spacing: 12) {
                Text("A Smart Trackpad board connects by itself when plugged in. Use this only for a board that is not recognised: choose its port and open it.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Board port", selection: $selectedPort) {
                    Text("Choose a port").tag("")
                    ForEach(usb.ports, id: \.self) { Text($0).tag($0) }
                }.disabled(usb.opened || connection.active)
                HStack {
                    Button("Refresh ports") { usb.refresh() }
                    Button(usb.opened ? "Close board USB" : "Open board USB") {
                        if usb.opened {
                            if connection.activeTransport == .wired { connection.disconnect() }
                            usb.stop()
                        } else { connection.openBoardUSB(path: selectedPort) }
                    }.disabled(!usb.opened && (selectedPort.isEmpty || connection.active))
                }
                Text(usb.status).font(.footnote).foregroundStyle(.secondary)
            }.padding(.top, 12)
        }.onAppear { usb.refresh() }
    }
}
