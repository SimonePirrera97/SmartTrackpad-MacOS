import Foundation
import Combine
@preconcurrency import CoreBluetooth
import Network

/// An opaque byte relay. TLS terminates only in ConnectionModel, not here.
/// UUIDs and byte ordering are the embedded client contract; no Swift payloads.
@MainActor
final class BluetoothTransport: NSObject, ObservableObject {
    static let serviceID = CBUUID(string: "ADCA1000-7D6D-4D46-ACF4-13F29B8A67E1")
    static let receiveID = CBUUID(string: "ADCA1001-7D6D-4D46-ACF4-13F29B8A67E1")
    static let transmitID = CBUUID(string: "ADCA1002-7D6D-4D46-ACF4-13F29B8A67E1")
    static let fastReceiveID = CBUUID(string: "ADCA1003-7D6D-4D46-ACF4-13F29B8A67E1")
    static let acknowledgmentID = CBUUID(string: "ADCA1004-7D6D-4D46-ACF4-13F29B8A67E1")
    struct Peer: Identifiable { let id: UUID; let name: String }
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var status = "Bluetooth is off in this app"
    @Published private(set) var enabled = false
    @Published private(set) var available = false
    @Published private(set) var availabilityMessage = "Checking Bluetooth availability…"
    var onDrain: (() -> Void)?
    var canAccept: (() -> Bool)?
    var onFailure: ((String) -> Void)?
    private let server: Bool
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var found: [UUID: CBPeripheral] = [:]
    private var peer: CBPeripheral?
    private var subscribedCentral: CBCentral?
    private var receiveCharacteristic: CBCharacteristic?
    private var transmitCharacteristic: CBMutableCharacteristic?
    private var fastReceiveCharacteristic: CBCharacteristic?
    private var acknowledgmentCharacteristic: CBCharacteristic?
    private var serverAcknowledgment: CBMutableCharacteristic?
    private var acknowledgmentSubscriber: CBCentral?
    private var pendingAcknowledgment: Data?
    private var writeWindow = BLEWriteWindow(token: UInt64.random(in: 1...UInt64.max))
    private var writeReceiver = BLEWriteReceiver()
    private var retryWrites: Task<Void, Never>?
    private var fastWrites = false
    var usesReliableWindow: Bool { fastWrites }
    private var notifyReady = false
    private var acknowledgmentReady = false
    private var windowLoaded = false
    private var writeLimit = 0
    var diagnostics: String {
        "\(fastWrites ? "Reliable window" : "Acknowledged writes"), payload limit \(writeLimit), pending \(writeWindow.count), frames \(writeWindow.sentFrames), retries \(writeWindow.retransmissions), max ack \(String(format: "%.1f", writeWindow.maximumAckMilliseconds)) ms"
    }
    private var targetPort: UInt16 = 0
    private var proxy: NWListener?
    private var pipe: StreamByteRelay?
    private var outgoing = Data()
    private var delivered: (() -> Void)?
    private var writePending = false
    private var pendingWriteCount = 0
    private var readyHandler: ((UInt16) -> Void)?
    private var serviceAdded = false
    private var timeout: Task<Void, Never>?

    init(server: Bool) { self.server = server; super.init() }
    var hasSession: Bool { pipe != nil || peer != nil || subscribedCentral != nil }

    func start(targetPort: UInt16 = 0) {
        self.targetPort = targetPort
        enabled = true
        if server {
            if peripheralManager == nil { peripheralManager = CBPeripheralManager(delegate: self, queue: .main) }
            else { advertiseIfReady() }
        } else {
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
            else { scanIfReady() }
        }
    }

    func stop() {
        enabled = false
        closeSession()
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        serviceAdded = false
        found = [:]; peers = []
        status = "Bluetooth is off in this app"
    }

    func connect(id: UUID, ready: @escaping (UInt16) -> Void) {
        guard !server, enabled, central?.state == .poweredOn, let next = found[id] else {
            fail("Select a Bluetooth Mac first"); return
        }
        closeSession()
        peer = next
        readyHandler = ready
        next.delegate = self
        central?.stopScan()
        status = "Connecting over Bluetooth…"
        central?.connect(next)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.fail("Bluetooth connection timed out")
        }
    }

    func closeSession() {
        timeout?.cancel(); timeout = nil
        let old = peer
        peer = nil; subscribedCentral = nil
        receiveCharacteristic = nil
        fastReceiveCharacteristic = nil; acknowledgmentCharacteristic = nil
        acknowledgmentSubscriber = nil; pendingAcknowledgment = nil
        writeWindow = BLEWriteWindow(token: UInt64.random(in: 1...UInt64.max))
        writeReceiver = BLEWriteReceiver()
        retryWrites?.cancel(); retryWrites = nil
        fastWrites = false; notifyReady = false; acknowledgmentReady = false; windowLoaded = false; writeLimit = 0
        readyHandler = nil
        let oldProxy = proxy; proxy = nil; oldProxy?.cancel()
        let oldPipe = pipe; pipe = nil; oldPipe?.close()
        outgoing = Data(); delivered = nil; writePending = false; pendingWriteCount = 0
        if let old { central?.cancelPeripheralConnection(old) }
        if enabled {
            if server { status = "Bluetooth pairing available" }
            else { scanIfReady() }
        }
    }

    private func fail(_ reason: String) {
        closeSession()
        status = reason
        onFailure?(reason)
    }

    private func scanIfReady() {
        guard enabled, !server, central?.state == .poweredOn, peer == nil else { return }
        status = "Looking for Bluetooth Macs…"
        central?.scanForPeripherals(withServices: [Self.serviceID])
    }

    private func advertiseIfReady() {
        guard enabled, server, peripheralManager?.state == .poweredOn else { return }
        if !serviceAdded {
            let rx = CBMutableCharacteristic(type: Self.receiveID, properties: [.write], value: nil, permissions: [.writeable])
            let tx = CBMutableCharacteristic(type: Self.transmitID, properties: [.notify], value: nil, permissions: [])
            let fast = CBMutableCharacteristic(type: Self.fastReceiveID, properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
            let ack = CBMutableCharacteristic(type: Self.acknowledgmentID, properties: [.notify], value: nil, permissions: [])
            serverAcknowledgment = ack
            transmitCharacteristic = tx
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [rx, tx, fast, ack]
            serviceAdded = true
            peripheralManager?.add(service)
        } else {
            peripheralManager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
                CBAdvertisementDataLocalNameKey: "Smart Trackpad Mac"])
        }
    }

    private func stateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: "Turn on Bluetooth in Settings"
        case .unauthorized: "Allow Bluetooth access for Smart Trackpad in Settings"
        case .unsupported: "Bluetooth LE is unavailable on this device"
        case .resetting: "Bluetooth is restarting"
        default: "Waiting for Bluetooth…"
        }
    }

    private func makePipe(_ socket: NWConnection) {
        let next = StreamByteRelay(socket: socket)
        pipe = next
        next.onFailure = { [weak self, weak next] reason in
            guard let self, let next, self.pipe === next else { return }
            self.fail(reason)
        }
        next.onBytes = { [weak self, weak next] bytes, completion in
            guard let self, let next, self.pipe === next else { return }
            guard self.outgoing.isEmpty else { self.fail("Bluetooth send overlap"); return }
            self.outgoing = bytes
            self.delivered = completion
            self.pump()
        }
        next.start()
        status = "Bluetooth link established · checking pairing key"
    }

    private func startProxy() {
        guard proxy == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            proxy = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.proxy === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else { self.fail("Bluetooth relay has no port"); return }
                        self.timeout?.cancel(); self.timeout = nil
                        let ready = self.readyHandler; self.readyHandler = nil
                        ready?(port.rawValue)
                    case .failed(let error): self.fail("Bluetooth relay: \(error.localizedDescription)")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] socket in
                Task { @MainActor in
                    guard let self, let listener, self.proxy === listener, self.pipe == nil else { socket.cancel(); return }
                    self.makePipe(socket)
                }
            }
            listener.start(queue: .main)
        } catch { fail("Bluetooth relay: \(error.localizedDescription)") }
    }

    private func pump() {
        if !server, fastWrites {
            pumpWindow()
            return
        }
        guard !outgoing.isEmpty else {
            let callback = delivered; delivered = nil
            callback?()
            if callback != nil { onDrain?() }
            return
        }
        if server {
            guard let manager = peripheralManager, let subscriber = subscribedCentral,
                  let characteristic = transmitCharacteristic else { fail("Bluetooth subscriber lost"); return }
            while !outgoing.isEmpty {
                let chunk = Data(outgoing.prefix(subscriber.maximumUpdateValueLength))
                guard manager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [subscriber]) else { return }
                outgoing.removeFirst(chunk.count)
            }
            let callback = delivered; delivered = nil
            callback?()
            if callback != nil { onDrain?() }
        } else {
            guard !writePending, let peer, let characteristic = receiveCharacteristic else { return }
            let chunk = Data(outgoing.prefix(peer.maximumWriteValueLength(for: .withResponse)))
            writeLimit = chunk.count
            pendingWriteCount = chunk.count
            writePending = true
            peer.writeValue(chunk, for: characteristic, type: .withResponse)
            // Keep bytes until ATT confirms the write. Never send another write in flight.
        }
    }

    private func pumpWindow() {
        guard let peer, let characteristic = fastReceiveCharacteristic else { return }
        do {
            if !windowLoaded, !outgoing.isEmpty {
                try writeWindow.enqueue(outgoing); windowLoaded = true
                if retryWrites == nil {
                    retryWrites = Task { [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(100))
                            guard !Task.isCancelled, let self else { return }
                            self.pumpWindow()
                        }
                    }
                }
            }
            writeLimit = peer.maximumWriteValueLength(for: .withoutResponse) - BLEWriteWindow.headerSize
            guard writeLimit > 0 else { fail("Bluetooth command payload unavailable"); return }
            while peer.canSendWriteWithoutResponse,
                  let packet = try writeWindow.next(at: ProcessInfo.processInfo.systemUptime, payloadLimit: writeLimit) {
                peer.writeValue(packet, for: characteristic, type: .withoutResponse)
            }
            if windowLoaded, writeWindow.idle {
                retryWrites?.cancel(); retryWrites = nil
                outgoing.removeAll(keepingCapacity: true); windowLoaded = false
                let callback = delivered; delivered = nil
                callback?()
                if callback != nil { onDrain?() }
            }
        } catch { fail("Bluetooth command stream invalid") }
    }

    private func pumpAcknowledgment() {
        guard let bytes = pendingAcknowledgment, let manager = peripheralManager,
              let subscriber = acknowledgmentSubscriber, let characteristic = serverAcknowledgment else { return }
        if manager.updateValue(bytes, for: characteristic, onSubscribedCentrals: [subscriber]) {
            pendingAcknowledgment = nil
        }
    }

    private func startWhenSubscribed() {
        guard notifyReady, !fastWrites || acknowledgmentReady else { return }
        startProxy()
    }
}

extension BluetoothTransport: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        available = central.state == .poweredOn
        availabilityMessage = available ? "Bluetooth LE is available." : "Bluetooth LE is unavailable. \(stateDescription(central.state))"
        if central.state == .poweredOn { scanIfReady() }
        else { fail(stateDescription(central.state)) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled, peer == nil else { return }
        found[peripheral.identifier] = peripheral
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Smart Trackpad Mac"
        peers = found.values.map { Peer(id: $0.identifier, name: $0.identifier == peripheral.identifier ? name : ($0.name ?? "Smart Trackpad Mac")) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        status = "Bluetooth Macs found"
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === peer else { return }
        peripheral.discoverServices([Self.serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === peer else { return }
        fail("Bluetooth connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === peer else { return }
        fail("Bluetooth peer disconnected")
    }
}

extension BluetoothTransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === peer else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            fail("Bluetooth trackpad service unavailable"); return
        }
        peripheral.discoverCharacteristics([Self.receiveID, Self.transmitID, Self.fastReceiveID, Self.acknowledgmentID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === peer else { return }
        guard error == nil,
              let rx = service.characteristics?.first(where: { $0.uuid == Self.receiveID }), rx.properties.contains(.write),
              let tx = service.characteristics?.first(where: { $0.uuid == Self.transmitID }), tx.properties.contains(.notify) else {
            fail("Bluetooth characteristics unavailable"); return
        }
        receiveCharacteristic = rx
        if let fast = service.characteristics?.first(where: { $0.uuid == Self.fastReceiveID }), fast.properties.contains(.writeWithoutResponse),
           let ack = service.characteristics?.first(where: { $0.uuid == Self.acknowledgmentID }), ack.properties.contains(.notify) {
            fastReceiveCharacteristic = fast; acknowledgmentCharacteristic = ack
            fastWrites = true
            peripheral.setNotifyValue(true, for: ack)
        }
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer, characteristic.uuid == Self.transmitID || characteristic.uuid == Self.acknowledgmentID else { return }
        guard error == nil, characteristic.isNotifying else { fail("Bluetooth notifications unavailable"); return }
        if characteristic.uuid == Self.transmitID { notifyReady = true }
        else { acknowledgmentReady = true }
        startWhenSubscribed()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer else { return }
        if characteristic.uuid == Self.acknowledgmentID {
            guard fastWrites, error == nil, let bytes = characteristic.value else { fail("Bluetooth acknowledgment unavailable"); return }
            do { try writeWindow.acknowledge(bytes, at: ProcessInfo.processInfo.systemUptime); pumpWindow() }
            catch { fail("Bluetooth acknowledgment invalid") }
            return
        }
        guard characteristic.uuid == Self.transmitID else { return }
        guard error == nil, let bytes = characteristic.value, let pipe else { fail("Bluetooth receive failed"); return }
        pipe.accept(bytes)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === peer, characteristic.uuid == Self.receiveID, writePending else { return }
        guard error == nil else { fail("Bluetooth write failed"); return }
        let count = pendingWriteCount
        outgoing.removeFirst(count)
        writePending = false
        pump()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === peer else { return }
        pumpWindow()
    }
}

extension BluetoothTransport: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { advertiseIfReady() }
        else { serviceAdded = false; fail(stateDescription(peripheral.state)) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard enabled else { return }
        guard error == nil else { serviceAdded = false; fail("Cannot publish Bluetooth service"); return }
        advertiseIfReady()
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard enabled else { return }
        if let error { fail("Bluetooth advertising failed: \(error.localizedDescription)") }
        else if pipe == nil { status = "Bluetooth pairing available" }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if characteristic.uuid == Self.acknowledgmentID {
            guard enabled, acknowledgmentSubscriber == nil,
                  subscribedCentral == nil || subscribedCentral?.identifier == central.identifier,
                  canAccept?() != false || subscribedCentral?.identifier == central.identifier else { return }
            acknowledgmentSubscriber = central
            return
        }
        guard enabled, characteristic.uuid == Self.transmitID, subscribedCentral == nil, canAccept?() != false else { return }
        guard acknowledgmentSubscriber == nil || acknowledgmentSubscriber?.identifier == central.identifier else { return }
        subscribedCentral = central
        let socket = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!, using: .tcp)
        makePipe(socket)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard central.identifier == subscribedCentral?.identifier || central.identifier == acknowledgmentSubscriber?.identifier else { return }
        fail("Bluetooth peer disconnected")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Validate the whole batch before modifying the byte stream.
        guard enabled, let pipe, requests.allSatisfy({
            $0.central.identifier == subscribedCentral?.identifier && ($0.characteristic.uuid == Self.receiveID || $0.characteristic.uuid == Self.fastReceiveID)
                && $0.offset == 0 && $0.value != nil
        }) else {
            if let first = requests.first, first.characteristic.uuid == Self.receiveID { peripheral.respond(to: first, withResult: .unlikelyError) }
            return
        }
        for request in requests {
            if request.characteristic.uuid == Self.fastReceiveID {
                guard acknowledgmentSubscriber?.identifier == request.central.identifier else { fail("Bluetooth command channel was not subscribed"); return }
                do {
                    let result = try writeReceiver.accept(request.value!)
                    if let bytes = result.bytes { pipe.accept(bytes) }
                    pendingAcknowledgment = result.acknowledgment
                    fastWrites = true
                } catch { fail("Bluetooth command packet invalid"); return }
            } else {
                guard !fastWrites else { fail("Bluetooth write modes changed during a stream"); return }
                pipe.accept(request.value!)
            }
        }
        pumpAcknowledgment()
        if let first = requests.first, first.characteristic.uuid == Self.receiveID { peripheral.respond(to: first, withResult: .success) }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pumpAcknowledgment(); pump() }
}

