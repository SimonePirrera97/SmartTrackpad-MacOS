import Foundation
import Network
import Combine
import OSLog

/// Apple transport adapter. Wire messages contain no Apple UI or Network types.
@MainActor
final class ConnectionModel: ObservableObject {
    enum Role { case client, server }
    static let port: UInt16 = 47821
    static let bonjourType = "_smarttrackpad._tcp"
    /// The iPad listens here on loopback; the Mac reaches it through USBMux.
    static let cablePort: UInt16 = 47822

    @Published var status = "Not connected"
    @Published var pairingCode = ""
    @Published var awaitingApproval = false
    @Published var connected = false
    @Published var active = false
    @Published var listening = false
    @Published private(set) var pairingKey = ""
    @Published private(set) var authenticated = false
    var onInput: ((InputCommand) -> Void)?
    var onResetInput: (() -> Void)?
    var appContextSnapshot: (() -> AppControlContext)?
    @Published private(set) var appContext: AppControlContext?
    var preferenceSnapshot: (() -> TrackpadPreferences?)?
    @Published private(set) var macPreferences: TrackpadPreferences?
    var localCapabilities: [String]
    @Published private(set) var messagesSent: UInt64 = 0
    @Published private(set) var messagesReceived: UInt64 = 0
    private var totalSent: UInt64 = 0
    private var totalReceived: UInt64 = 0
    private var inputQueue = InputQueue()
    private var inputInFlight = false
    private var inputSendStarted = 0.0
    private var bytesSent: UInt64 = 0
    private var bytesReceived: UInt64 = 0
    private var maximumSendMilliseconds = 0.0
    private var inputAcknowledgments = InputAcknowledgmentWindow()
    #if TRACKPAD_TESTING
    private var testInputWindow = false
    #endif
    private var requestsInputWindow: Bool {
        #if TRACKPAD_TESTING
        if testInputWindow { return true }
        #endif
        return activeTransport == .bluetooth && bluetooth.usesReliableWindow
    }
    private var usesInputWindow: Bool {
        requestsInputWindow && peerCapabilities.contains(InputAcknowledgmentWindow.capability)
            && peerCapabilities.contains(CompactInputPacket.capability)
    }
    private var lastPublishedAppContext: AppControlContext?

    #if os(macOS)
    let boardUSB = USBSerialTransport()
    private let cableUSB = USBSerialTransport()
    #endif
    let bluetooth: BluetoothTransport
    @Published private(set) var activeTransport: ConnectionTransport = .wifi
    @Published private(set) var routeDescription = "No route"
    private let role: Role
    @Published private(set) var cableStatus = "Looking for an iPad on USB…"
    /// iPad: waiting for the Mac to open the cable session.
    @Published private(set) var cableListening = false
    @Published private(set) var cableConnectionsEnabled = false
    @Published private(set) var directCableSession = false
    /// Mac: a board's permanent key is stored, so that board connects by itself.
    @Published private(set) var boardRemembered = false
    /// Mac: a board is on the cable and can be given its key now.
    @Published private(set) var canRememberBoard = false
    /// Mac: the current session is the remembered board over Wi-Fi or Bluetooth.
    @Published private(set) var boardSession = false
    private let boardKeys: BoardKeyStore
    private var pendingBoardKey: Data?
    private var peerHoldsBoardKey = false
    /// The iPad pairing key. It survives listener restarts and is only shown
    /// once the user has started connections.
    private var sessionKey: String?
    private var pairingVisible = false
    private var listenerRetries = 0
    /// The cabled board has no key yet, or holds one this Mac does not know.
    var boardNeedsKey: Bool { canRememberBoard && !(boardRemembered && peerHoldsBoardKey) }
    var sessionAuthorized: Bool { authenticated || directCableSession }
    /// The board's serial port is relayed through a loopback socket.
    private var boardSerialOpen: Bool {
        #if os(macOS)
        boardUSB.sessionReady
        #else
        false
        #endif
    }
    private var cableListener: NWListener?
    private var cableMonitor: Task<Void, Never>?
    /// Set when the Mac user ends a cable session, so it is not reopened at once.
    private var cableHeld = false
    private var resting = false
    private static let restingReason = "Mac asleep or lid closed · reconnects when it is back"
    private let log = Logger(subsystem: "SmartTrackpad", category: "connection")
    #if TRACKPAD_TESTING
    private var testCableDisabled = false
    #endif
    private var serialListener: NWListener?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var messageIO = SessionMessageIO()
    private var session = ""
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var receivedTimestamp: UInt64 = 0
    private var peerCapabilities: Set<String> = []
    private var minimumTransitOffset: Double?
    private var lastReceived = ProcessInfo.processInfo.systemUptime
    private var maintenance: Task<Void, Never>?
    private var lastDisconnectReason = "None"
    #if os(macOS)
    private var networkActivity: NSObjectProtocol?
    #endif

    init(role: Role, boardKeys: BoardKeyStore? = nil) {
        self.role = role
        #if TRACKPAD_TESTING
        self.boardKeys = boardKeys ?? .memory()
        #else
        self.boardKeys = boardKeys ?? .keychain
        #endif
        bluetooth = BluetoothTransport(server: role == .server)
        localCapabilities = InputKind.supportedCapabilities.filter {
            role == .client || !$0.hasSuffix(".experimental")
        }
        #if os(macOS)
        for usb in [boardUSB, cableUSB] {
            usb.onFailure = { [weak self] reason in
                guard let self, self.active, self.activeTransport == .wired else { return }
                self.disconnect(reason: reason)
            }
        }
        #endif
        // Pace input at BLE delivery, rather than loopback TCP kernel acceptance.
        // Heartbeat/TLS records may share a read; the bounded input FIFO still
        // coalesces motion while acknowledged ATT writes are in progress.
        bluetooth.onDrain = { [weak self] in
            guard let self, self.role == .client, self.activeTransport == .bluetooth, self.inputInFlight else { return }
            guard !self.usesInputWindow else { return }
            self.inputInFlight = false
            self.recordInputSendTime()
            self.flushInput()
        }
        bluetooth.canAccept = { [weak self] in self?.active == false }
        bluetooth.onFailure = { [weak self] reason in
            guard let self, self.active, self.activeTransport == .bluetooth else { return }
            self.disconnect(reason: reason)
        }
        if role == .server {
            startCableConnections()
            // A remembered board must find the Mac without anyone clicking Start.
            if self.boardKeys.load() != nil {
                boardRemembered = true
                openListener()
                enableBluetooth()
            }
        }
    }

    /// Mac: give the cabled board a permanent key. Completes when it confirms.
    func rememberBoard() {
        guard role == .server, canRememberBoard, connected, directCableSession,
              let text = try? PairingSecret.generate(), let key = try? PairingSecret.decode(text) else { return }
        pendingBoardKey = key
        send(.enroll, enrollment: BoardEnrollment(key: text, host: ProcessInfo.processInfo.hostName,
                                                  name: Self.macName))
    }

    func forgetBoard() {
        guard role == .server else { return }
        boardKeys.delete()
        boardRemembered = false
        peerHoldsBoardKey = false
        if boardSession { disconnect(reason: "Board forgotten") }
        // Without a board or a visible pairing key nothing should be listening.
        if pairingVisible { openListener() }
        else { listener?.cancel(); listener = nil; updateNetworkActivity() }
    }

    private static var macName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Smart Trackpad Mac"
        #else
        "Smart Trackpad"
        #endif
    }

    /// Mac: once a second, look for a cabled iPad whose app is waiting, or for the
    /// dedicated board, and open a session to it. Both arrive as the same USB byte
    /// stream. Nothing to select, pair or approve: the cable is trusted.
    func startCableConnections() {
        #if os(macOS)
        guard role == .server, cableMonitor == nil else { return }
        #if TRACKPAD_TESTING
        if testCableDisabled { return }
        #endif
        cableConnectionsEnabled = true
        cableHeld = false
        cableStatus = "Looking for an iPad on USB…"
        updateNetworkActivity()
        cableMonitor = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.active, !self.resting {
                    // Port 0 never answers: while held, only watch for the unplug.
                    let port = self.cableHeld ? 0 : Self.cablePort
                    let probe = await Task.detached { USBMux.probe(port: port) }.value
                    guard !Task.isCancelled else {
                        if case .connected(let descriptor) = probe { Darwin.close(descriptor) }
                        return
                    }
                    let board = USBSerialTransport.boardPort
                    switch probe {
                    case .noDevice where board != nil:
                        if self.cableHeld {
                            self.cableStatus = "Cable session ended · unplug and replug the board to reconnect"
                        } else if !self.boardUSB.opened {
                            self.log.notice("opening board USB port \(board!, privacy: .public)")
                            self.cableStatus = "Smart Trackpad board on USB · connecting"
                            self.openBoardUSB(path: board!)
                        }
                    case .noDevice:
                        self.cableHeld = false
                        self.cableStatus = "No iPad or board connected by cable"
                    case .waiting:
                        self.cableStatus = self.cableHeld
                            ? "Cable session ended · unplug and replug the iPad to reconnect"
                            : "iPad on cable · open Smart Trackpad on it and choose Wired"
                    case .connected(let descriptor):
                        if self.active || self.cableHeld { Darwin.close(descriptor) }
                        else {
                            self.cableStatus = "iPad on cable · connecting"
                            self.openSerialSession { self.cableUSB.relay(descriptor: descriptor, name: "iPad cable", targetPort: $0) }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #endif
    }

    /// iPad: wait on loopback for the Mac to open the cable session.
    func startCableListening() {
        guard role == .client, cableListener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.cablePort)!)
            parameters.allowLocalEndpointReuse = true
            if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
            let next = try NWListener(using: parameters)
            cableListener = next
            cableListening = true
            next.newConnectionHandler = { [weak self, weak next] peer in
                Task { @MainActor in
                    guard let self, let next, self.cableListener === next, !self.active else { peer.cancel(); return }
                    self.activeTransport = .wired
                    self.session = UUID().uuidString
                    self.attach(peer, directCable: true)
                }
            }
            next.stateUpdateHandler = { [weak self, weak next] state in
                Task { @MainActor in
                    guard let self, let next, self.cableListener === next else { return }
                    if case .failed(let error) = state {
                        self.stopCableListening()
                        self.status = "Cannot wait for the cable: \(error.localizedDescription)"
                    }
                }
            }
            next.start(queue: .main)
        } catch { status = "Cannot wait for the cable: \(error.localizedDescription)" }
    }

    func stopCableListening() {
        cableListener?.cancel()
        cableListener = nil
        cableListening = false
    }

    #if os(macOS)
    func openBoardUSB(path: String) {
        guard role == .server, !active else { return }
        openSerialSession { self.boardUSB.start(path: path, targetPort: $0) }
    }

    /// A USB byte stream joins the session machinery through a loopback socket,
    /// exactly like any other peer. `start` receives the port to relay into.
    private func openSerialSession(_ start: @escaping @MainActor (UInt16) -> Void) {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let next = try NWListener(using: parameters)
            serialListener?.cancel()
            serialListener = next
            next.newConnectionHandler = { [weak self, weak next] peer in
                Task { @MainActor in
                    guard let self, let next, self.serialListener === next,
                          self.boardUSB.sessionReady || self.cableUSB.opened, !self.active else { peer.cancel(); return }
                    self.attach(peer, directCable: true)
                }
            }
            next.stateUpdateHandler = { [weak self, weak next] state in
                Task { @MainActor in
                    guard let self, let next, self.serialListener === next else { return }
                    if case .ready = state, let port = next.port { start(port.rawValue) }
                    else if case .failed(let error) = state { self.status = "USB listener failed: \(error.localizedDescription)" }
                }
            }
            next.start(queue: .main)
        } catch { status = "Cannot start USB session: \(error.localizedDescription)" }
    }
    #endif

    func enableBluetooth() {
        if role == .server && listener == nil { startListening() }
        guard role == .client || listener != nil else { return }
        bluetooth.start(targetPort: Self.port)
    }

    func connectBluetooth(id: UUID, key: String) {
        guard role == .client else { return }
        let secret: Data
        do { secret = try PairingSecret.decode(key) }
        catch { status = error.localizedDescription; return }
        disconnect()
        activeTransport = .bluetooth
        active = true
        session = UUID().uuidString
        pairingCode = String(format: "%06d", Int.random(in: 0...999999))
        status = "Connecting over Bluetooth…"
        bluetooth.connect(id: id) { [weak self] port in
            guard let self, self.active, self.activeTransport == .bluetooth else { return }
            let peer = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                    using: SecureTransport.parameters(key: secret))
            self.attach(peer)
        }
    }

    var supportsStandardActions: Bool { connected && peerCapabilities.contains("action.standard") }
    var supportsPageSwipe: Bool { connected && peerCapabilities.contains("gesture.pages.experimental") }
    var supportsMissionControl: Bool { connected && peerCapabilities.contains("gesture.missionControl.experimental") }
    var supportsShowDesktop: Bool { connected && peerCapabilities.contains("action.showDesktop.experimental") }
    var supportsNativePinch: Bool { connected && peerCapabilities.contains("gesture.magnify.experimental") }

    var diagnostics: String {
        """
        Smart Trackpad · protocol \(WireMessage.currentVersion)
        Role: \(role == .server ? "Mac" : "iPad")
        Status: \(status)
        Transport: \(activeTransport.title), route: \(routeDescription)
        Last disconnect: \(lastDisconnectReason)
        Listening: \(listening), active: \(active), TLS authenticated: \(authenticated), approved: \(connected)
        Sent: \(totalSent), received: \(totalReceived), queued input: \(inputQueue.count)
        Input format: \(peerCapabilities.contains(CompactInputPacket.capability) ? "Binary v1" : "JSON v2")
        Bytes sent/received: \(bytesSent)/\(bytesReceived); max input send: \(String(format: "%.1f", maximumSendMilliseconds)) ms
        Queue peak: \(inputQueue.highWater), coalesced: \(inputQueue.coalesced), stale dropped: \(inputQueue.staleDropped)
        Input ACK window pending: \(inputAcknowledgments.count)/\(InputAcknowledgmentWindow.capacity)
        USB: \(cableStatus)
        BLE: \(bluetooth.diagnostics)
        Capabilities: \(peerCapabilities.sorted().joined(separator: ", "))
        """
    }

    /// User action: also show the iPad pairing key.
    func startListening() {
        startCableConnections()
        guard role == .server else { return }
        pairingVisible = true
        if listener == nil { openListener() }
        else if listening { pairingKey = sessionKey ?? "" }
    }

    /// (Re)creates the wireless listener for the iPad key and, if one is
    /// remembered, the board key. An existing cable session is unaffected.
    private func openListener() {
        guard role == .server else { return }
        listener?.cancel(); listener = nil
        listening = false
        do {
            let key = try sessionKey ?? PairingSecret.generate()
            sessionKey = key
            let parameters = SecureTransport.parameters(key: try PairingSecret.decode(key), boardKey: boardKeys.load())
            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            newListener.service = NWListener.Service(name: Self.macName, type: Self.bonjourType, domain: "local.")
            listener = newListener
            updateNetworkActivity()
            if pairingVisible { status = "Starting listener…" }
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                Task { @MainActor in
                    guard let self, let newListener, self.listener === newListener else { return }
                    switch state {
                    case .ready:
                        self.listenerRetries = 0
                        self.listening = self.pairingVisible
                        if self.pairingVisible { self.pairingKey = key }
                        if !self.active, self.pairingVisible { self.status = "Waiting for iPad · port \(Self.port)" }
                    case .failed(let error):
                        self.listener?.cancel(); self.listener = nil
                        self.listening = false; self.pairingKey = ""
                        if !self.active || self.activeTransport != .wired {
                            self.disconnect(reason: "Listener failed: \(error.localizedDescription)")
                        }
                        self.updateNetworkActivity()
                        // Reopening right after closing can find the port still busy.
                        if self.listenerRetries < 5, self.pairingVisible || self.boardRemembered {
                            self.listenerRetries += 1
                            try? await Task.sleep(for: .seconds(1))
                            if self.listener == nil, self.pairingVisible || self.boardRemembered { self.openListener() }
                        } else { self.bluetooth.stop() }
                    case .waiting(let error):
                        self.status = "Listener waiting: \(error.localizedDescription) · check Local Network permission"
                    default: break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self, weak newListener] peer in
                Task { @MainActor in
                    guard let self, let newListener, self.listener === newListener, !self.active else { peer.cancel(); return }
                    self.attach(peer)
                }
            }
            newListener.start(queue: .main)
        } catch { pairingKey = ""; status = "Cannot listen: \(error.localizedDescription)" }
    }

    func stopListening() {
        cableConnectionsEnabled = false
        cableMonitor?.cancel()
        cableMonitor = nil
        cableStatus = "Cable connections stopped"
        bluetooth.stop()
        #if os(macOS)
        boardUSB.stop()
        #endif
        listener?.cancel()
        listener = nil
        listening = false
        pairingVisible = false
        sessionKey = nil
        pairingKey = ""
        disconnect()
    }

    func connect(host: String, key: String, transport: ConnectionTransport? = nil) {
        guard role == .client else { return }
        let invitation: PairingInvitation
        let parameters: NWParameters
        do {
            invitation = try PairingEntry.invitation(address: host, keyOrInvitation: key)
            parameters = SecureTransport.parameters(key: try PairingSecret.decode(invitation.key))
        }
        catch { status = error.localizedDescription; return }
        transport?.configure(parameters)
        connect(to: .hostPort(host: NWEndpoint.Host(invitation.host),
                              port: NWEndpoint.Port(rawValue: invitation.port)!), parameters: parameters, transport: transport ?? .wifi)
    }

    func connect(to endpoint: NWEndpoint, key: String, transport: ConnectionTransport? = nil) {
        guard role == .client else { return }
        do {
            let parameters = SecureTransport.parameters(key: try PairingSecret.decode(key))
            transport?.configure(parameters)
            connect(to: endpoint, parameters: parameters, transport: transport ?? .wifi)
        }
        catch { status = error.localizedDescription }
    }

    private func connect(to endpoint: NWEndpoint, parameters: NWParameters, transport: ConnectionTransport) {
        disconnect()
        activeTransport = transport
        session = UUID().uuidString
        pairingCode = String(format: "%06d", Int.random(in: 0...999999))
        let peer = NWConnection(to: endpoint, using: parameters)
        attach(peer)
    }

    private func attach(_ peer: NWConnection, directCable: Bool = false) {
        directCableSession = directCable
        connection = peer
        if directCable { activeTransport = .wired }
        else if role == .server {
            if case .hostPort(let host, _) = peer.endpoint,
               host == NWEndpoint.Host("127.0.0.1") || host == NWEndpoint.Host("::1") {
                activeTransport = boardSerialOpen ? .wired : (bluetooth.hasSession ? .bluetooth : .wifi)
            } else { activeTransport = .wifi }
        }
        updateNetworkActivity()
        active = true
        sent = 0
        received = 0
        receivedTimestamp = 0
        peerCapabilities = []
        macPreferences = nil
        appContext = nil
        minimumTransitOffset = nil
        messageIO = SessionMessageIO()
        inputAcknowledgments = InputAcknowledgmentWindow()
        bytesSent = 0; bytesReceived = 0; maximumSendMilliseconds = 0
        lastPublishedAppContext = nil
        if role == .server { session = ""; pairingCode = "" }
        lastReceived = ProcessInfo.processInfo.systemUptime
        status = role == .server ? (directCable ? "Starting cable session…" : "Receiving pairing request…") : "Connecting…"
        peer.stateUpdateHandler = { [weak self, weak peer] state in
            Task { @MainActor in
                guard let self, let peer, self.connection === peer else { return }
                switch state {
                case .ready:
                    guard self.directCableSession || SecureTransport.authenticated(peer) else {
                        self.disconnect(reason: "TLS authentication failed · no connection accepted")
                        return
                    }
                    if self.boardSerialOpen && self.activeTransport == .wired {
                        self.routeDescription = "Board USB serial · direct CDC/UART"
                    } else if self.activeTransport == .bluetooth {
                        self.routeDescription = "Bluetooth LE · TLS over GATT"
                    } else if self.directCableSession {
                        self.routeDescription = "USB cable · direct byte stream, no TLS or pairing"
                    } else if peer.currentPath?.usesInterfaceType(.wiredEthernet) == true {
                        self.activeTransport = .wired
                        self.routeDescription = "Wired Ethernet"
                    } else {
                        self.routeDescription = peer.currentPath.map { String(describing: $0) } ?? "Unknown network route"
                    }
                    self.authenticated = !self.directCableSession
                    if self.role == .client {
                        if self.directCableSession {
                            self.send(.sessionRequest)
                            self.status = "Connecting to Mac over cable…"
                        } else {
                            self.send(.pairRequest, code: self.pairingCode)
                            self.status = "Approve code \(self.pairingCode) on the Mac"
                        }
                    }
                    self.receive(peer)
                case .failed(let error), .waiting(let error):
                    let help = self.directCableSession ? "Check the USB cable." : "Check the selected connection, Mac address and current pairing key."
                    self.disconnect(reason: "Cannot connect: \(error.localizedDescription). \(help)")
                case .cancelled: self.disconnect()
                default: break
                }
            }
        }
        peer.start(queue: .main)
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.connection === peer else { return }
                self.publishCounts()
                let limit: Double = self.connected ? 3.5 : 60
                if ProcessInfo.processInfo.systemUptime - self.lastReceived > limit {
                    self.disconnect(reason: "Connection timed out · try again")
                    return
                }
                if self.connected { self.send(.heartbeat) }
            }
        }
    }

    private func receive(_ peer: NWConnection) {
        messageIO.receive(from: peer) { [weak self, weak peer] result, complete, byteCount in
            Task { @MainActor in
                guard let self, let peer, self.connection === peer else { return }
                do {
                    self.bytesReceived += UInt64(byteCount)
                    for packet in try result.get() {
                            switch packet {
                            case .json(let message): try self.handle(message)
                            case .compact(let input):
                                guard self.connected, self.peerCapabilities.contains(CompactInputPacket.capability) else { throw WireError.invalidMessage }
                                var message = WireMessage(version: 2, session: self.session, sequence: input.sequence,
                                    timestampMilliseconds: input.timestamp, type: .input, code: nil)
                                message.input = input.input
                                try message.validate()
                                try self.handle(message)
                            case .acknowledgment(let ack):
                                guard self.connected, self.usesInputWindow else { throw WireError.invalidMessage }
                                var message = WireMessage(version: 2, session: self.session, sequence: ack.sequence,
                                    timestampMilliseconds: ack.timestamp, type: .heartbeat, code: nil)
                                message.acknowledgedInputSequence = ack.inputSequence
                                try self.handle(message)
                            }
                            guard self.connection === peer else { return }
                    }
                    if complete {
                        self.disconnect(reason: "Peer disconnected")
                    } else { self.receive(peer) }
                } catch { self.disconnect(reason: "Invalid peer message · disconnected") }
            }
        }
    }

    private func handle(_ message: WireMessage) throws {
        guard message.sequence > received, message.timestampMilliseconds >= receivedTimestamp else { throw WireError.invalidMessage }
        if role == .server, session.isEmpty {
            guard message.type == (directCableSession ? .sessionRequest : .pairRequest) else { throw WireError.invalidMessage }
            session = message.session
        }
        guard message.session == session else { throw WireError.invalidMessage }
        received = message.sequence
        receivedTimestamp = message.timestampMilliseconds
        totalReceived += 1
        let now = ProcessInfo.processInfo.systemUptime
        let offset = now - Double(message.timestampMilliseconds) / 1000
        minimumTransitOffset = min(minimumTransitOffset ?? offset, offset)
        if offset - (minimumTransitOffset ?? offset) <= 0.25 { lastReceived = now }
        switch message.type {
        case .pairRequest, .sessionRequest:
            guard (message.type == .sessionRequest) == directCableSession,
                  role == .server, !connected, !awaitingApproval else { throw WireError.invalidMessage }
            if resting { endForRest(); return }
            pairingCode = message.code ?? ""
            peerCapabilities = Set(message.capabilities!)
            let offersEnrollment = peerCapabilities.contains(BoardKeyStore.capability)
            peerHoldsBoardKey = peerCapabilities.contains(BoardKeyStore.enrolledCapability)
            guard !peerCapabilities.isDisjoint(with: localCapabilities) else {
                send(.pairReject, closeAfter: "Client has no supported input capabilities")
                return
            }
            if directCableSession {
                peerCapabilities.formIntersection(localCapabilities)
                connected = true
                send(.sessionAccept)
                status = "Connected to client · Wired"
                canRememberBoard = offersEnrollment
            } else if let proof = message.boardProof {
                // A remembered board proves its key instead of waiting for approval.
                guard let key = boardKeys.load(), BoardKeyStore.accepts(proof: proof, key: key, session: session) else {
                    send(.pairReject, closeAfter: "Unknown board refused")
                    return
                }
                peerCapabilities.formIntersection(localCapabilities)
                pairingCode = ""
                connected = true
                boardSession = true
                // The board has moved on to wireless, so an earlier "disconnect
                // from the cable" no longer applies when it is switched back to USB.
                cableHeld = false
                log.notice("remembered board connected over \(self.activeTransport.title, privacy: .public)")
                send(.pairAccept)
                status = "Connected to board · \(activeTransport.title)"
            } else {
                awaitingApproval = true
                status = "Compare code \(pairingCode) with your iPad"
            }
        case .pairAccept, .sessionAccept:
            guard (message.type == .sessionAccept) == directCableSession,
                  role == .client, !connected else { throw WireError.invalidMessage }
            connected = true
            peerCapabilities = Set(message.capabilities!).intersection(localCapabilities)
            guard !peerCapabilities.isEmpty else { throw WireError.invalidMessage }
            macPreferences = peerCapabilities.contains("settings.trackpadPreferences") ? message.trackpadPreferences : nil
            appContext = peerCapabilities.contains("action.appControls.v2") ? message.appContext : nil
            status = directCableSession ? "Connected to Mac · Wired" : "Connected securely to Mac · \(activeTransport.title)"
        case .enroll:
            // Only the dedicated board firmware accepts a key, and only by cable.
            throw WireError.invalidMessage
        case .enrolled:
            guard role == .server, connected, directCableSession, let key = pendingBoardKey else { throw WireError.invalidMessage }
            pendingBoardKey = nil
            guard boardKeys.save(key) else { status = "Could not store the board key"; return }
            boardRemembered = true
            peerHoldsBoardKey = true
            openListener()
            enableBluetooth()
        case .pairReject:
            guard role == .client, !connected else { throw WireError.invalidMessage }
            disconnect(reason: "Mac declined the connection")
        case .heartbeat:
            guard connected else { throw WireError.invalidMessage }
            if let acknowledged = message.acknowledgedInputSequence {
                guard role == .client, usesInputWindow else { throw WireError.invalidMessage }
                if let duration = try inputAcknowledgments.acknowledge(acknowledged, at: now) {
                    maximumSendMilliseconds = max(maximumSendMilliseconds, duration)
                    flushInput()
                }
            }
            if let context = message.appContext {
                guard role == .client, peerCapabilities.contains("action.appControls.v2") else { throw WireError.invalidMessage }
                if appContext != context { appContext = context }
            }
        case .input:
            guard role == .server, connected, sessionAuthorized, let command = message.input,
                  peerCapabilities.contains(command.kind.capability) else {
                throw WireError.invalidMessage
            }
            if command.kind == .scroll, let delta = command.delta, !delta.valid,
               !peerCapabilities.contains("scroll.pixel.highRange") { throw WireError.invalidMessage }
            defer {
                if peerCapabilities.contains(InputAcknowledgmentWindow.capability), peerCapabilities.contains(CompactInputPacket.capability) {
                    send(.heartbeat, acknowledgedInput: message.sequence)
                }
            }
            // Estimate excess transit delay without assuming synchronized clocks.
            // Releases are always delivered so nothing stays held.
            guard command.releases || offset - (minimumTransitOffset ?? offset) <= 0.25 else { return }
            onInput?(command)
        case .disconnect:
            disconnect(reason: "Peer disconnected")
        }
    }

    func approve() {
        guard awaitingApproval, authenticated else { return }
        awaitingApproval = false
        peerCapabilities.formIntersection(localCapabilities)
        connected = true
        lastReceived = ProcessInfo.processInfo.systemUptime
        send(.pairAccept)
        status = "Connected securely to client · \(activeTransport.title)"
    }

    func reject() {
        guard awaitingApproval else { return }
        awaitingApproval = false
        send(.pairReject, closeAfter: "Connection declined")
    }

    func refreshAppContext() {
        guard role == .server, connected, sessionAuthorized, peerCapabilities.contains("action.appControls.v2") else { return }
        send(.heartbeat)
    }

    func sendInput(_ command: InputCommand) {
        guard role == .client, connected, sessionAuthorized, command.valid, peerCapabilities.contains(command.kind.capability) else { return }
        var compatible = command
        if command.kind == .scroll, !peerCapabilities.contains("scroll.pixel.highRange"), let delta = command.delta {
            compatible.delta = PointerDelta(dx: max(-128, min(128, delta.dx)), dy: max(-128, min(128, delta.dy)))
        }
        guard inputQueue.append(compatible, at: ProcessInfo.processInfo.systemUptime) else {
            disconnect(reason: "Input queue full · reconnect to continue")
            return
        }
        flushInput()
    }

    private func flushInput() {
        if usesInputWindow {
            guard connected, sessionAuthorized else { return }
            while inputAcknowledgments.available,
                  let command = inputQueue.pop(at: ProcessInfo.processInfo.systemUptime) {
                send(.input, input: command)
                guard connected else { return }
            }
            return
        }
        guard !inputInFlight, connected, sessionAuthorized,
              var command = inputQueue.pop(at: ProcessInfo.processInfo.systemUptime) else { return }
        if command.kind == .scroll, !peerCapabilities.contains("scroll.pixel.highRange"), let delta = command.delta {
            command.delta = PointerDelta(dx: max(-128, min(128, delta.dx)), dy: max(-128, min(128, delta.dy)))
        }
        inputInFlight = true
        inputSendStarted = ProcessInfo.processInfo.systemUptime
        send(.input, input: command)
    }

    private func recordInputSendTime() {
        maximumSendMilliseconds = max(maximumSendMilliseconds, (ProcessInfo.processInfo.systemUptime - inputSendStarted) * 1000)
    }

    private func send(_ type: MessageKind, code: String? = nil, input: InputCommand? = nil, closeAfter: String? = nil, acknowledgedInput: UInt64? = nil, enrollment: BoardEnrollment? = nil, sleeping: Bool = false) {
        guard let peer = connection, !session.isEmpty else { return }
        sent += 1
        var message = WireMessage(version: WireMessage.currentVersion, session: session, sequence: sent,
            timestampMilliseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1000), type: type, code: code)
        message.input = input
        message.acknowledgedInputSequence = acknowledgedInput
        message.enrollment = enrollment
        if sleeping { message.sleeping = true }
        if type == .pairRequest || type == .sessionRequest {
            message.capabilities = localCapabilities.filter {
                $0 != InputAcknowledgmentWindow.capability || (requestsInputWindow && localCapabilities.contains(CompactInputPacket.capability))
            }
        }
        if type == .pairAccept || type == .sessionAccept {
            message.capabilities = localCapabilities.filter { peerCapabilities.contains($0) }
            if peerCapabilities.contains("settings.trackpadPreferences") { message.trackpadPreferences = preferenceSnapshot?() }
        }
        if role == .server, (type == .pairAccept || type == .sessionAccept || type == .heartbeat), peerCapabilities.contains("action.appControls.v2") {
            let context = appContextSnapshot?()
            if type != .heartbeat || context != lastPublishedAppContext {
                message.appContext = context
                lastPublishedAppContext = context
            }
        }
        totalSent += 1
        if type == .input, usesInputWindow {
            do { try inputAcknowledgments.track(sent, at: ProcessInfo.processInfo.systemUptime) }
            catch { disconnect(reason: "Input acknowledgment window full"); return }
        }
        messageIO.send(message, compact: (type == .input || acknowledgedInput != nil) && peerCapabilities.contains(CompactInputPacket.capability), to: peer) { [weak self, weak peer] error, size in
                Task { @MainActor in
                    guard let self, let peer, self.connection === peer else { return }
                    self.bytesSent += UInt64(size)
                    if error != nil || closeAfter != nil {
                        self.disconnect(reason: error.map { "Send failed: \($0.localizedDescription)" } ?? closeAfter)
                    } else if type == .input, self.activeTransport != .bluetooth, !self.usesInputWindow {
                        self.inputInFlight = false
                        self.recordInputSendTime()
                        self.flushInput()
                    }
                }
        }
    }

    /// Mac: asleep, or the lid is closed with no other display. The session ends
    /// with a note that lets a board darken its screen, and no cable or wireless
    /// session is accepted until this is cleared.
    func setResting(_ resting: Bool) {
        guard role == .server, resting != self.resting else { return }
        self.resting = resting
        log.notice("Mac \(resting ? "resting: sessions paused" : "in use again", privacy: .public)")
        guard resting, active else { return }
        onResetInput?()
        if connected { endForRest() } else { disconnect(reason: Self.restingReason) }
    }

    /// Says "sleeping" and then closes. The close waits a moment: a cable or
    /// Bluetooth session is relayed through a loopback socket, and closing at
    /// once would tear the relay down before it has passed the message on.
    private func endForRest() {
        send(.disconnect, sleeping: true)
        let ending = connection
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let ending, self.connection === ending else { return }
            self.disconnect(reason: Self.restingReason)
        }
    }

    func disconnect(reason: String? = nil) {
        lastDisconnectReason = reason ?? "Local disconnect"
        if active { log.notice("session ended: \(self.lastDisconnectReason, privacy: .public)") }
        if role == .server, directCableSession, reason == nil { cableHeld = true }
        publishCounts()
        maintenance?.cancel()
        maintenance = nil
        inputQueue.reset()
        inputAcknowledgments = InputAcknowledgmentWindow()
        inputInFlight = false
        peerCapabilities = []
        macPreferences = nil
        appContext = nil
        onResetInput?()
        let old = connection
        connection = nil
        updateNetworkActivity()
        old?.cancel()
        bluetooth.closeSession()
        serialListener?.cancel(); serialListener = nil
        directCableSession = false
        canRememberBoard = false
        boardSession = false
        pendingBoardKey = nil
        #if os(macOS)
        boardUSB.stop()
        cableUSB.stop()
        #endif
        routeDescription = "No route"
        connected = false
        authenticated = false
        active = false
        awaitingApproval = false
        pairingCode = ""
        session = ""
        messageIO = SessionMessageIO()
        status = reason ?? (listening ? "Waiting for iPad · port \(Self.port)" : "Not connected")
    }

    /// Only the Mac panel shows live counters; publishing them on the client
    /// would redraw the whole trackpad view once a second for nothing.
    private func publishCounts() {
        guard role == .server else { return }
        if messagesSent != totalSent { messagesSent = totalSent }
        if messagesReceived != totalReceived { messagesReceived = totalReceived }
    }

    private func updateNetworkActivity() {
        #if os(macOS)
        // A hidden companion must keep serving pairing and heartbeats. Permit normal
        // system sleep; CompanionService still disconnects and releases input on sleep.
        if listener != nil || connection != nil || cableConnectionsEnabled {
            if networkActivity == nil {
                networkActivity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Serve the user-requested Smart Trackpad connection")
            }
        } else if let activity = networkActivity {
            ProcessInfo.processInfo.endActivity(activity)
            networkActivity = nil
        }
        #endif
    }
}

#if TRACKPAD_TESTING
// Compile-time-only hooks for direct-session tests; absent from application builds.
extension ConnectionModel {
    func testEnableInputWindow() { testInputWindow = true }
    var testOutstandingInputs: Int { inputAcknowledgments.count }
    #if os(macOS)
    /// Checks must never reach for a cabled iPad or board that happens to be attached.
    func testStopCableMonitor() { testCableDisabled = true; cableMonitor?.cancel(); cableMonitor = nil }
    var testCableHeld: Bool { cableHeld }
    func testOpenCable(descriptor: Int32) {
        cableHeld = false
        openSerialSession { self.cableUSB.relay(descriptor: descriptor, name: "iPad cable", targetPort: $0) }
    }
    #endif
    func testAttach(_ peer: NWConnection, direct: Bool) {
        if role == .client { session = UUID().uuidString }
        attach(peer, directCable: direct)
    }
}
#endif
