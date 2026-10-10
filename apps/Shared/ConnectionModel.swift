import Foundation
import Network
import Combine

/// Apple transport adapter. Wire messages contain no Apple UI or Network types.
@MainActor
final class ConnectionModel: ObservableObject {
    enum Role { case client, server }
    static let port: UInt16 = 47821
    static let bonjourType = "_smarttrackpad._tcp"

    @Published var status = "Not connected"
    @Published var pairingCode = ""
    @Published var awaitingApproval = false
    @Published var connected = false
    @Published var active = false
    @Published var listening = false
    @Published private(set) var pairingKey = ""
    @Published private(set) var authenticated = false
    var onPointerMove: ((PointerDelta) -> Void)?
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

    private let role: Role
    private var listener: NWListener?
    private var connection: NWConnection?
    private var framer = LineFramer()
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

    init(role: Role) {
        self.role = role
        localCapabilities = InputKind.supportedCapabilities.filter {
            role == .client || !$0.hasSuffix(".experimental")
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
        Last disconnect: \(lastDisconnectReason)
        Listening: \(listening), active: \(active), TLS authenticated: \(authenticated), approved: \(connected)
        Sent: \(messagesSent), received: \(messagesReceived), queued input: \(inputQueue.count)
        Capabilities: \(peerCapabilities.sorted().joined(separator: ", "))
        """
    }

    func startListening() {
        guard role == .server, listener == nil else { return }
        do {
            let key = try PairingSecret.generate()
            let parameters = SecureTransport.parameters(key: try PairingSecret.decode(key))
            let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            #if os(macOS)
            newListener.service = NWListener.Service(name: Host.current().localizedName ?? "Smart Trackpad Mac",
                                                    type: Self.bonjourType, domain: "local.")
            #endif
            listener = newListener
            updateNetworkActivity()
            pairingKey = key
            status = "Starting listener…"
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                Task { @MainActor in
                    guard let self, let newListener, self.listener === newListener else { return }
                    switch state {
                    case .ready:
                        self.listening = true
                        if !self.active { self.status = "Waiting for iPad · port \(Self.port)" }
                    case .failed(let error):
                        self.stopListening()
                        self.status = "Listener failed: \(error.localizedDescription)"
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
        listener?.cancel()
        listener = nil
        listening = false
        pairingKey = ""
        disconnect()
    }

    func connect(host: String, key: String) {
        guard role == .client else { return }
        let invitation: PairingInvitation
        let parameters: NWParameters
        do {
            invitation = try PairingEntry.invitation(address: host, keyOrInvitation: key)
            parameters = SecureTransport.parameters(key: try PairingSecret.decode(invitation.key))
        }
        catch { status = error.localizedDescription; return }
        connect(to: .hostPort(host: NWEndpoint.Host(invitation.host),
                              port: NWEndpoint.Port(rawValue: invitation.port)!), parameters: parameters)
    }

    func connect(to endpoint: NWEndpoint, key: String) {
        guard role == .client else { return }
        do { connect(to: endpoint, parameters: SecureTransport.parameters(key: try PairingSecret.decode(key))) }
        catch { status = error.localizedDescription }
    }

    private func connect(to endpoint: NWEndpoint, parameters: NWParameters) {
        disconnect()
        session = UUID().uuidString
        pairingCode = String(format: "%06d", Int.random(in: 0...999999))
        let peer = NWConnection(to: endpoint, using: parameters)
        attach(peer)
    }

    private func attach(_ peer: NWConnection) {
        connection = peer
        updateNetworkActivity()
        active = true
        sent = 0
        received = 0
        receivedTimestamp = 0
        peerCapabilities = []
        macPreferences = nil
        appContext = nil
        minimumTransitOffset = nil
        framer = LineFramer()
        if role == .server { session = ""; pairingCode = "" }
        lastReceived = ProcessInfo.processInfo.systemUptime
        status = role == .server ? "Receiving pairing request…" : "Connecting…"
        peer.stateUpdateHandler = { [weak self, weak peer] state in
            Task { @MainActor in
                guard let self, let peer, self.connection === peer else { return }
                switch state {
                case .ready:
                    guard SecureTransport.authenticated(peer) else {
                        self.disconnect(reason: "TLS authentication failed · no connection accepted")
                        return
                    }
                    self.authenticated = true
                    if self.role == .client {
                        self.send(.pairRequest, code: self.pairingCode)
                        self.status = "Approve code \(self.pairingCode) on the Mac"
                    }
                    self.receive(peer)
                case .failed(let error), .waiting(let error):
                    self.disconnect(reason: "Cannot connect: \(error.localizedDescription). Check the Mac Wi-Fi address and copy fresh pairing details; both devices must be on the same network.")
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
                self.messagesSent = self.totalSent
                self.messagesReceived = self.totalReceived
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
        peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak peer] data, _, complete, error in
            Task { @MainActor in
                guard let self, let peer, self.connection === peer else { return }
                do {
                    if let data {
                        for message in try self.framer.append(data) {
                            try self.handle(message)
                            guard self.connection === peer else { return }
                        }
                    }
                    if complete || error != nil {
                        self.disconnect(reason: "Peer disconnected")
                    } else { self.receive(peer) }
                } catch { self.disconnect(reason: "Invalid peer message · disconnected") }
            }
        }
    }

    private func handle(_ message: WireMessage) throws {
        guard message.sequence > received, message.timestampMilliseconds >= receivedTimestamp else { throw WireError.invalidMessage }
        if role == .server, session.isEmpty {
            guard message.type == .pairRequest else { throw WireError.invalidMessage }
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
        case .pairRequest:
            guard role == .server, !connected, !awaitingApproval else { throw WireError.invalidMessage }
            pairingCode = message.code!
            peerCapabilities = Set(message.capabilities!)
            guard !peerCapabilities.isDisjoint(with: localCapabilities) else {
                send(.pairReject, closeAfter: "Client has no supported input capabilities")
                return
            }
            awaitingApproval = true
            status = "Compare code \(pairingCode) with your iPad"
        case .pairAccept:
            guard role == .client, !connected else { throw WireError.invalidMessage }
            connected = true
            peerCapabilities = Set(message.capabilities!).intersection(localCapabilities)
            guard !peerCapabilities.isEmpty else { throw WireError.invalidMessage }
            macPreferences = peerCapabilities.contains("settings.trackpadPreferences") ? message.trackpadPreferences : nil
            appContext = peerCapabilities.contains("action.appControls.v2") ? message.appContext : nil
            status = "Connected securely to Mac"
        case .pairReject:
            guard role == .client, !connected else { throw WireError.invalidMessage }
            disconnect(reason: "Mac declined the connection")
        case .heartbeat:
            guard connected else { throw WireError.invalidMessage }
            if let context = message.appContext {
                guard role == .client, peerCapabilities.contains("action.appControls.v2") else { throw WireError.invalidMessage }
                appContext = context
            }
        case .pointerMove:
            guard role == .server, connected, authenticated, peerCapabilities.contains("pointer.move"), let delta = message.delta else {
                throw WireError.invalidMessage
            }
            // Estimate excess transit delay without assuming synchronized clocks.
            guard offset - (minimumTransitOffset ?? offset) <= 0.25 else { return }
            onPointerMove?(delta)
        case .input:
            guard role == .server, connected, authenticated, let command = message.input,
                  peerCapabilities.contains(command.kind.capability) else {
                throw WireError.invalidMessage
            }
            if command.kind == .scroll, let delta = command.delta, !delta.valid,
               !peerCapabilities.contains("scroll.pixel.highRange") { throw WireError.invalidMessage }
            let release = command.kind == .releaseAll
                || (command.kind == .button && command.pressed == false)
                || command.endsGesture
            guard release || offset - (minimumTransitOffset ?? offset) <= 0.25 else { return }
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
        status = "Connected securely to iPad"
    }

    func reject() {
        guard awaitingApproval else { return }
        awaitingApproval = false
        send(.pairReject, closeAfter: "Connection declined")
    }

    func refreshAppContext() {
        guard role == .server, connected, authenticated, peerCapabilities.contains("action.appControls.v2") else { return }
        send(.heartbeat)
    }

    func sendPointer(_ delta: PointerDelta) { sendInput(.move(delta)) }

    func sendInput(_ command: InputCommand) {
        guard role == .client, connected, authenticated, command.valid, peerCapabilities.contains(command.kind.capability) else { return }
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
        guard !inputInFlight, connected, authenticated,
              var command = inputQueue.pop(at: ProcessInfo.processInfo.systemUptime) else { return }
        if command.kind == .scroll, !peerCapabilities.contains("scroll.pixel.highRange"), let delta = command.delta {
            command.delta = PointerDelta(dx: max(-128, min(128, delta.dx)), dy: max(-128, min(128, delta.dy)))
        }
        inputInFlight = true
        send(.input, input: command)
    }

    private func send(_ type: MessageKind, code: String? = nil, delta: PointerDelta? = nil, input: InputCommand? = nil, closeAfter: String? = nil) {
        guard let peer = connection, !session.isEmpty else { return }
        sent += 1
        var message = WireMessage(version: WireMessage.currentVersion, session: session, sequence: sent,
            timestampMilliseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1000), type: type, code: code)
        message.delta = delta
        message.input = input
        if type == .pairRequest { message.capabilities = localCapabilities }
        if type == .pairAccept {
            message.capabilities = localCapabilities.filter { peerCapabilities.contains($0) }
            if peerCapabilities.contains("settings.trackpadPreferences") { message.trackpadPreferences = preferenceSnapshot?() }
        }
        if role == .server, (type == .pairAccept || type == .heartbeat), peerCapabilities.contains("action.appControls.v2") {
            message.appContext = appContextSnapshot?()
        }
        totalSent += 1
        do {
            peer.send(content: try message.encoded(), completion: .contentProcessed { [weak self, weak peer] error in
                guard error != nil || closeAfter != nil || type == .input else { return }
                Task { @MainActor in
                    guard let self, let peer, self.connection === peer else { return }
                    if error != nil || closeAfter != nil {
                        self.disconnect(reason: error.map { "Send failed: \($0.localizedDescription)" } ?? closeAfter)
                    } else if type == .input {
                        self.inputInFlight = false
                        self.flushInput()
                    }
                }
            })
        } catch { disconnect(reason: "Could not encode message") }
    }

    func disconnect(reason: String? = nil) {
        lastDisconnectReason = reason ?? "Local disconnect"
        messagesSent = totalSent
        messagesReceived = totalReceived
        maintenance?.cancel()
        maintenance = nil
        inputQueue.reset()
        inputInFlight = false
        peerCapabilities = []
        macPreferences = nil
        appContext = nil
        onResetInput?()
        let old = connection
        connection = nil
        updateNetworkActivity()
        old?.cancel()
        connected = false
        authenticated = false
        active = false
        awaitingApproval = false
        pairingCode = ""
        session = ""
        framer = LineFramer()
        status = reason ?? (listening ? "Waiting for iPad · port \(Self.port)" : "Not connected")
    }

    private func updateNetworkActivity() {
        #if os(macOS)
        // A hidden companion must keep serving pairing and heartbeats. Permit normal
        // system sleep; CompanionService still disconnects and releases input on sleep.
        if listener != nil || connection != nil {
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
