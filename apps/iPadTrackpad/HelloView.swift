import SwiftUI

struct HelloView: View {
    @StateObject private var connection = ConnectionModel(role: .client)
    @StateObject private var address = MacAddress()
    @StateObject private var settings = TrackpadSettings()
    @StateObject private var scanner = PairingScannerModel()
    @StateObject private var discovery = MacDiscovery()
    @StateObject private var availability = TransportAvailability()
    @State private var transport: ConnectionTransport = .wired
    @State private var bluetoothMacID: UUID?
    @StateObject private var entry = PairingEntryModel()
    @Environment(\.scenePhase) private var scenePhase

    private var gestureOptions: GestureOptions {
        var options = settings.options
        options.pageSwipes = settings.pageSwipes && connection.supportsPageSwipe
        options.interactiveMissionControl = settings.threeFingerMissionControl && connection.supportsMissionControl
        options.threeFingerMissionControl = false
        options.nativePinch = settings.pinchEnabled && connection.supportsNativePinch
        return options
    }

    var body: some View {
        Group {
            if connection.connected {
                VStack(spacing: 14) {
                    HStack {
                        Label("Smart Trackpad", systemImage: "computermouse").font(.title2.bold())
                        Spacer()
                        Button { settings.showSettings = true } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        Text("|").foregroundStyle(.secondary).accessibilityHidden(true)
                        Button("Disconnect") { connection.disconnect() }
                    }
                    Label(connection.status, systemImage: connection.directCableSession ? "cable.connector" : "lock.shield")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        TrackpadSurface(options: gestureOptions, releaseGeneration: settings.releaseGeneration) { command in
                            if command.kind == .button && command.button == .left {
                                settings.dragging = command.pressed ?? false
                            }
                            for scaled in settings.scaledCommands(command) { connection.sendInput(scaled) }
                        } onHoldStatus: { status in
                            if settings.holdStatus != status { settings.holdStatus = status }
                        }
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: settings.dragging ? "hand.draw.fill" : "hand.draw")
                                    .font(.largeTitle)
                                Text(settings.dragging ? "Dragging · lift to release" : settings.holdStatus)
                                Text("Two fingers to scroll or right-click · hold to drag")
                                    .font(.footnote)
                            }
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        EditingActionStrip(enabled: connection.supportsStandardActions, desktopEnabled: connection.supportsShowDesktop, context: connection.appContext, showDesktop: {
                            settings.releaseGeneration &+= 1
                            settings.dragging = false
                            connection.sendInput(.showDesktop)
                        }, performApp: { request in
                            settings.releaseGeneration &+= 1
                            settings.dragging = false
                            connection.sendInput(.app(request))
                        }) { action in
                            settings.releaseGeneration &+= 1
                            settings.dragging = false
                            connection.sendInput(.action(action))
                        }
                        .frame(width: 180)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                }
                .padding(24)
            } else {
                setupView
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                discovery.stop()
                connection.bluetooth.stop()
                settings.dragging = false
                connection.disconnect(reason: "App backgrounded · reconnect when ready")
            } else if phase == .active && !connection.connected {
                startDiscovery()
            }
        }
        .sheet(isPresented: $settings.showSettings) {
            TrackpadSettingsView(settings: settings, nativePinchAvailable: connection.supportsNativePinch, missionControlAvailable: connection.supportsMissionControl, pagesAvailable: connection.supportsPageSwipe, macPreferences: connection.macPreferences)
                .onAppear { settings.releaseGeneration &+= 1; connection.sendInput(.releaseAll); settings.dragging = false }
        }
        .fullScreenCover(isPresented: $scanner.presented) {
            PairingScannerView { invitation in
                apply(invitation)
                scanner.presented = false
            } onError: { error in
                scanner.error = error
                scanner.presented = false
            }
        }
        .onChange(of: connection.connected) { _, connected in
            settings.dragging = false
            UIApplication.shared.isIdleTimerDisabled = connected
        }
    }


    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func startDiscovery() {
        if transport == .bluetooth { connection.enableBluetooth() }
        else { discovery.start(transport: transport) }
    }

    private func apply(_ invitation: PairingInvitation) {
        address.value = invitation.host
        address.pairingKey = invitation.key
        entry.useEnteredAddress = transport != .bluetooth
        entry.pasteError = nil
    }

    private var nearbyMacs: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(transport == .wired ? "Mac on USB cable" : "Nearby Macs").font(.headline)
            if discovery.macs.isEmpty {
                Text(discovery.status).font(.subheadline).foregroundStyle(.secondary)
                Button("Search again") { discovery.stop(); startDiscovery() }
                    .disabled(connection.active)
            } else {
                Picker("Connect to", selection: $entry.selectedMacID) {
                    Text("Choose a Mac").tag("")
                    ForEach(discovery.macs) { mac in Text(mac.name).tag(mac.id) }
                }
                .disabled(connection.active)
                Text(transport == .wired ? "Select the Mac connected by USB cable. No key or approval code is needed." : "Copy the pairing key from this Mac. You do not need to type its address.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !entry.useEnteredAddress && transport != .wired {
                Text("Pairing key").font(.subheadline.bold())
                SecureField("Paste the key copied from your Mac", text: $address.pairingKey)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(connection.active)
            }
        }
    }

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "computermouse")
                        .font(.system(size: 56)).foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Connect to your Mac").font(.largeTitle.bold())
                    Text("Open Smart Trackpad on your Mac and start connections. \(transport.instructions)")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Connection", selection: $transport) {
                            ForEach(ConnectionTransport.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).disabled(connection.active)
                        if transport == .bluetooth {
                            BluetoothAvailabilityView(bluetooth: connection.bluetooth)
                        } else {
                            Text(transport == .wifi ? availability.wifiMessage : (discovery.macs.isEmpty ? "Waiting for a Mac on the USB cable. Unlock both devices and start connections on the Mac." : "Direct USB connection available."))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if transport == .wifi {
                            Button("Open Settings") { openSystemSettings() }
                            Text("Choose Wi-Fi in Settings to enable it or join a network. For app permissions, use this app’s Settings page.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("1. Choose your Mac").font(.headline)
                        if transport == .bluetooth {
                            BluetoothMacPicker(bluetooth: connection.bluetooth, selectedID: $bluetoothMacID)
                            SecureField("Paste the key copied from your Mac", text: $address.pairingKey)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .disabled(connection.active)
                        } else { nearbyMacs }
                        if transport != .wired {
                            Divider()
                            Button { Task { await scanner.present() } } label: {
                                Label("Scan Mac QR code", systemImage: "qrcode.viewfinder")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(connection.active)
                            Text("Paste your copied key below, or scan the QR code to fill everything automatically.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            PasteButton(payloadType: String.self) { values in
                                guard !connection.active, let text = values.first else { return }
                                do {
                                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if trimmed.hasPrefix(PairingInvitation.prefix) {
                                        apply(try PairingInvitation.decode(trimmed))
                                    } else {
                                        _ = try PairingSecret.decode(trimmed)
                                        address.pairingKey = trimmed
                                        entry.useEnteredAddress = false
                                        entry.pasteError = nil
                                    }
                                }
                                catch { entry.pasteError = error.localizedDescription }
                            }
                            .disabled(connection.active)
                            if let error = entry.pasteError ?? scanner.error {
                                Text(error).font(.subheadline).foregroundStyle(.red)
                            }
                            if !address.pairingKey.isEmpty {
                                Label("Pairing details entered", systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                                if entry.useEnteredAddress {
                                    Text("Mac address: \(address.value)").font(.subheadline.monospaced())
                                    Button("Use a nearby Mac instead") { entry.useEnteredAddress = false }
                                        .disabled(connection.active)
                                }
                            }
                            if transport != .bluetooth {
                                DisclosureGroup("Enter address and key manually", isExpanded: $entry.manualEntryExpanded) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Toggle("Use this address instead of discovery", isOn: $entry.useEnteredAddress)
                                        Text("Mac network address").font(.subheadline.bold())
                                        TextField("192.168.1.20", text: $address.value)
                                            .textFieldStyle(.roundedBorder).keyboardType(.URL)
                                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        Text("Pairing key").font(.subheadline.bold())
                                        SecureField("Paste the 64-character key from the Mac", text: $address.pairingKey)
                                            .textFieldStyle(.roundedBorder)
                                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        Text("Use the current address and key shown on the Mac. The six-digit approval code appears after connecting.")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    .padding(.top, 12).disabled(connection.active)
                                }
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        if transport == .wired, let error = entry.pasteError {
                            Text(error).font(.subheadline).foregroundStyle(.red)
                        }
                        Text(transport == .wired ? "2. Connect" : "2. Connect and approve").font(.headline)
                        Label(connection.status, systemImage: transport == .wired ? "cable.connector" : (connection.authenticated ? "lock.shield" : "wifi"))
                            .textSelection(.enabled)
                        if !connection.pairingCode.isEmpty && connection.authenticated {
                            Text(connection.pairingCode).font(.largeTitle.monospacedDigit())
                            Text("Compare this code with the Mac, then click Approve on the Mac.")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Connect") {
                                entry.pasteError = nil
                                if transport == .wired {
                                    if let mac = discovery.macs.first(where: { $0.id == entry.selectedMacID }) {
                                        connection.connectCable(to: mac.endpoint)
                                    } else { entry.pasteError = "Choose the Mac connected by cable first." }
                                } else if transport == .bluetooth {
                                    if let id = bluetoothMacID { connection.connectBluetooth(id: id, key: address.pairingKey) }
                                    else { entry.pasteError = "Choose a Bluetooth Mac first." }
                                } else if entry.useEnteredAddress {
                                    connection.connect(host: address.value, key: address.pairingKey, transport: transport)
                                } else if let mac = discovery.macs.first(where: { $0.id == entry.selectedMacID }) {
                                    connection.connect(to: mac.endpoint, key: address.pairingKey, transport: transport)
                                } else {
                                    entry.pasteError = "Choose a nearby Mac first, or scan its QR code."
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(connection.active || (transport != .wired && address.pairingKey.isEmpty)
                                || (transport == .wired && discovery.macs.isEmpty)
                                || (transport == .wifi && !availability.wifiAvailable))
                            if connection.active {
                                ProgressView().controlSize(.small)
                                Button("Cancel connection") { connection.disconnect() }
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(32).frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .onAppear { availability.start(); startDiscovery() }
        .onDisappear { discovery.stop() }
        .onChange(of: transport) { _, _ in
            discovery.stop()
            connection.bluetooth.stop()
            entry.selectedMacID = ""
            bluetoothMacID = nil
            entry.pasteError = nil
            if transport != .wifi { entry.useEnteredAddress = false }
            startDiscovery()
        }
        .onChange(of: discovery.macs.map(\.id)) { _, ids in
            if !ids.contains(entry.selectedMacID) { entry.selectedMacID = ids.count == 1 ? ids[0] : "" }
        }
    }

}

final class MacAddress: ObservableObject {
    @Published var pairingKey = ""
    @Published var value: String = UserDefaults.standard.string(forKey: "macAddress") ?? "" {
        didSet { UserDefaults.standard.set(value, forKey: "macAddress") }
    }
}

final class PairingEntryModel: ObservableObject {
    @Published var selectedMacID = ""
    @Published var useEnteredAddress = false
    @Published var manualEntryExpanded = false
    @Published var pasteError: String?
}


private struct BluetoothMacPicker: View {
    @ObservedObject var bluetooth: BluetoothTransport
    @Binding var selectedID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(bluetooth.status).font(.subheadline).foregroundStyle(.secondary)
            Picker("Bluetooth Mac", selection: $selectedID) {
                Text("Choose a Mac").tag(Optional<UUID>.none)
                ForEach(bluetooth.peers) { peer in Text(peer.name).tag(Optional(peer.id)) }
            }
            .disabled(bluetooth.hasSession)
            Button("Search again") { bluetooth.stop(); bluetooth.start() }
                .disabled(bluetooth.hasSession)
        }
        .onChange(of: bluetooth.peers.map(\.id)) { _, ids in
            if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.count == 1 ? ids.first : nil }
        }
    }
}


private struct BluetoothAvailabilityView: View {
    @ObservedObject var bluetooth: BluetoothTransport
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bluetooth.availabilityMessage).font(.subheadline).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Text("Choose Bluetooth in Settings to enable it. Allow Smart Trackpad Bluetooth access on this app’s Settings page.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
