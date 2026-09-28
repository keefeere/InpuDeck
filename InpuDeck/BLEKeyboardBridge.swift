import Combine
import CoreBluetooth
import Foundation

/// CoreBluetooth central for the ESP32-S3 BLE-to-USB bridge.
final class BLEKeyboardBridge: NSObject, ObservableObject, InputTransport {
    private let serviceUUID = CBUUID(string: "2D2A0001-8A5A-4E76-A2E3-1E57D9A1B001")
    private let writeCharUUID = CBUUID(string: "2D2A0002-8A5A-4E76-A2E3-1E57D9A1B001")
    private let securityCharUUID = CBUUID(string: "2D2A0003-8A5A-4E76-A2E3-1E57D9A1B001")
    private let nameCharUUID = CBUUID(string: "2D2A0004-8A5A-4E76-A2E3-1E57D9A1B001")
    private let requiredSecurityCapability = Data([0x49, 0x44, 0x01, 0x0F])
    private let restoreIdentifier = "com.keefeere.InpuDeck.central"
    @Published var statusText = localized("Bluetooth: ініціалізація…")
    @Published var isReady = false
    @Published private(set) var savedBridges: [SavedESPBridge] = []
    @Published private(set) var discoveredBridges: [DiscoveredESPBridge] = []
    @Published private(set) var selectedBridgeID: UUID?
    @Published private(set) var connectedBridgeID: UUID?
    @Published private(set) var isScanning = false
    @Published private(set) var firmwareSecurityIssue: ESPFirmwareSecurityIssue? = nil

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var securityChar: CBCharacteristic?
    private var nameChar: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private let bridgeStore = ESPBridgeStore()
    private var peers: [UUID: CBPeripheral] = [:]
    private var userRequestedScan = false

    private var pendingWrites: [Data] = []
    private var writeWithResponseInFlight = false
    private var isRunning = false
    private var possiblyHeldKeys: Set<UInt8> = []
    private var stopCompletion: (() -> Void)?
    private var stopDeadline: DispatchWorkItem?
    private var finishingStop = false

    override init() {
        super.init()
        savedBridges = bridgeStore.bridges
        selectedBridgeID = bridgeStore.selectedBridgeID
    }

    func start() {
        isRunning = true
        guard central == nil else {
            if central?.state == .poweredOn, !isReady {
                connectToSelectedBridgeOrScan()
            }
            return
        }

        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
    }

    func stop(completion: @escaping () -> Void) {
        isRunning = false
        reconnectWorkItem?.cancel()
        central?.stopScan()
        stopCompletion = completion
        releaseAllInput()
        isReady = false
        let deadline = DispatchWorkItem { [weak self] in self?.finishStop() }
        stopDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: deadline)
        finishStopIfDrained()
    }

    func releaseAllInput() {
        // Include keys whose key-up may still be in the discarded write queue.
        pendingWrites.removeAll()
        let releases = possiblyHeldKeys.sorted().map { V2Frame(command: V2.keyUp, payload: [$0]) }
        lastSentModifiersMask = 0
        writeV2(releases + [
            V2Frame(command: V2.setModifiers, payload: [0]),
            V2Frame(command: V2.consumerUp, payload: []),
            V2Frame(command: V2.systemMicrophoneMuteUp, payload: []),
            V2Frame(command: V2.mouseButtonUp, payload: [7])
        ])
    }

    private func finishStopIfDrained() {
        guard stopCompletion != nil, !finishingStop,
              pendingWrites.isEmpty, !writeWithResponseInFlight else { return }
        finishingStop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.finishStop() }
    }

    private func finishStop() {
        guard let completion = stopCompletion else { return }
        stopCompletion = nil
        stopDeadline?.cancel()
        stopDeadline = nil
        central?.stopScan()
        isScanning = false
        userRequestedScan = false
        peripheral?.delegate = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.delegate = nil
        central = nil
        peripheral = nil
        // CBPeripheral instances belong to the CBCentralManager that produced
        // them. Reusing one after recreating the manager leaves connect() in a
        // permanent waiting state until a fresh scan replaces the object.
        peers.removeAll()
        connectedBridgeID = nil
        resetConnectionState()
        finishingStop = false
        completion()
    }

    func reconnectNow() {
        guard isRunning else { return }
        releaseAllInput()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0

        if let peripheral, peripheral.state == .connected {
            central?.cancelPeripheralConnection(peripheral)
        } else if let peripheral, peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
            peers.removeValue(forKey: peripheral.identifier)
            self.peripheral = nil
            resetConnectionState()
            scanForBridges()
        } else {
            connectToSelectedBridgeOrScan()
        }
    }

    private struct V2Frame {
        let command: UInt8
        let payload: [UInt8]
    }

    private enum V2 {
        static let magic: UInt8 = 0xAA
        static let version: UInt8 = 0x01
        static let setModifiers: UInt8 = 0x01
        static let keyDown: UInt8 = 0x02
        static let keyUp: UInt8 = 0x03
        static let keyTap: UInt8 = 0x04
        static let mouseMove: UInt8 = 0x10
        static let mouseScroll: UInt8 = 0x11
        static let mouseClick: UInt8 = 0x12
        static let mouseButtonDown: UInt8 = 0x13
        static let mouseButtonUp: UInt8 = 0x14
        static let consumerDown: UInt8 = 0x20
        static let consumerUp: UInt8 = 0x21
        static let systemMicrophoneMuteDown: UInt8 = 0x22
        static let systemMicrophoneMuteUp: UInt8 = 0x23
    }

    private var lastSentModifiersMask: UInt8 = 0

    private var bridgeDisplayName: String {
        guard let selectedBridgeID else { return localized("ESP-адаптер") }
        return bridgeStore.bridge(selectedBridgeID)?.name
            ?? discoveredBridges.first(where: { $0.id == selectedBridgeID })?.displayName
            ?? localized("ESP-адаптер")
    }

    private func advertisedName(
        for peripheral: CBPeripheral,
        advertisementData: [String: Any]? = nil
    ) -> String? {
        let value = advertisementData?[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func publishStore() {
        savedBridges = bridgeStore.bridges
        selectedBridgeID = bridgeStore.selectedBridgeID
    }

    private func writeV2(_ frames: [V2Frame]) {
        guard isReady, let peripheral, let writeChar, !frames.isEmpty else { return }

        let writeType: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        let maximumLength = max(20, peripheral.maximumWriteValueLength(for: writeType))
        var packets: [Data] = []
        var frameIndex = 0

        while frameIndex < frames.count {
            var bytes: [UInt8] = [V2.magic, V2.version]

            while frameIndex < frames.count {
                let frame = frames[frameIndex]
                guard frame.payload.count <= 0xFF else {
                    frameIndex += 1
                    continue
                }

                let encodedLength = 2 + frame.payload.count
                if bytes.count + encodedLength > maximumLength {
                    break
                }

                bytes.append(frame.command)
                bytes.append(UInt8(frame.payload.count))
                bytes.append(contentsOf: frame.payload)
                frameIndex += 1
            }

            if bytes.count > 2 {
                packets.append(Data(bytes))
            } else {
                break
            }
        }

        pendingWrites.append(contentsOf: packets)
        drainWriteQueue(type: writeType)
    }

    private func drainWriteQueue(type: CBCharacteristicWriteType? = nil) {
        guard let peripheral, let writeChar, !pendingWrites.isEmpty else { return }
        let resolvedType = type ?? (writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)

        switch resolvedType {
        case .withoutResponse:
            while peripheral.canSendWriteWithoutResponse, !pendingWrites.isEmpty {
                peripheral.writeValue(pendingWrites.removeFirst(), for: writeChar, type: .withoutResponse)
            }
        case .withResponse:
            guard !writeWithResponseInFlight else { return }
            writeWithResponseInFlight = true
            peripheral.writeValue(pendingWrites.removeFirst(), for: writeChar, type: .withResponse)
        @unknown default:
            break
        }
        finishStopIfDrained()
    }

    private func modifierFrameIfNeeded(_ mask: UInt8) -> [V2Frame] {
        guard mask != lastSentModifiersMask else { return [] }
        lastSentModifiersMask = mask
        return [V2Frame(command: V2.setModifiers, payload: [mask])]
    }

    func setModifiers(_ mask: UInt8) {
        writeV2(modifierFrameIfNeeded(mask))
    }

    func sendKeyDown(modifiersMask: UInt8, keycode: UInt8) {
        if isReady, keycode != 0 { possiblyHeldKeys.insert(keycode) }
        var frames = modifierFrameIfNeeded(modifiersMask)
        frames.append(V2Frame(command: V2.keyDown, payload: [keycode]))
        writeV2(frames)
    }

    func sendKeyUp(keycode: UInt8) {
        possiblyHeldKeys.remove(keycode)
        writeV2([V2Frame(command: V2.keyUp, payload: [keycode])])
    }

    func sendKeyTap(modifiers: UInt8, hidKeycode: UInt8) {
        if hidKeycode == 0 {
            sendModifierChord(modifiers)
            return
        }
        writeV2([V2Frame(command: V2.keyTap, payload: [modifiers, hidKeycode])])
    }

    func sendKeyTaps(_ taps: [(modifiers: UInt8, keycode: UInt8)]) {
        var frames: [V2Frame] = []
        for tap in taps {
            if tap.keycode == 0 {
                frames.append(V2Frame(command: V2.setModifiers, payload: [tap.modifiers]))
                frames.append(V2Frame(command: V2.setModifiers, payload: [0]))
                lastSentModifiersMask = 0
            } else {
                frames.append(V2Frame(command: V2.keyTap, payload: [tap.modifiers, tap.keycode]))
            }
        }
        writeV2(frames)
    }

    private func sendModifierChord(_ modifiers: UInt8) {
        lastSentModifiersMask = 0
        writeV2([
            V2Frame(command: V2.setModifiers, payload: [modifiers]),
            V2Frame(command: V2.setModifiers, payload: [0])
        ])
    }

    func sendConsumerDown(usage: UInt16) {
        writeV2([V2Frame(command: V2.consumerDown, payload: [
            UInt8(usage & 0xFF), UInt8((usage >> 8) & 0xFF)
        ])])
    }

    func sendConsumerUp() {
        writeV2([V2Frame(command: V2.consumerUp, payload: [])])
    }

    func sendSystemMicrophoneMuteDown() {
        writeV2([V2Frame(command: V2.systemMicrophoneMuteDown, payload: [])])
    }

    func sendSystemMicrophoneMuteUp() {
        writeV2([V2Frame(command: V2.systemMicrophoneMuteUp, payload: [])])
    }

    func sendMouseMove(dx: Int8, dy: Int8) {
        writeV2([V2Frame(command: V2.mouseMove, payload: [UInt8(bitPattern: dx), UInt8(bitPattern: dy)])])
    }

    func sendMouseClick(button: UInt8) {
        writeV2([V2Frame(command: V2.mouseClick, payload: [button])])
    }

    func sendMouseScroll(dx: Int8, dy: Int8) {
        writeV2([V2Frame(command: V2.mouseScroll, payload: [UInt8(bitPattern: dx), UInt8(bitPattern: dy)])])
    }

    func sendMouseButtonDown(button: UInt8) {
        writeV2([V2Frame(command: V2.mouseButtonDown, payload: [button])])
    }

    func sendMouseButtonUp(button: UInt8) {
        writeV2([V2Frame(command: V2.mouseButtonUp, payload: [button])])
    }

    func selectBridge(_ id: UUID) {
        if selectedBridgeID != id { firmwareSecurityIssue = nil }
        let name = discoveredBridges.first(where: { $0.id == id })?.name
            ?? bridgeStore.bridge(id)?.advertisedName
        bridgeStore.select(id, name: name)
        publishStore()
        guard isRunning else { return }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        if peripheral?.identifier != id {
            if let peripheral {
                peripheral.delegate = nil
                central?.cancelPeripheralConnection(peripheral)
            }
            peripheral = nil
            connectedBridgeID = nil
            resetConnectionState()
        }
        connectToSelectedBridgeOrScan()
    }

    func beginDiscovery() {
        userRequestedScan = true
        discoveredBridges.removeAll()
        guard isRunning else { return }
        scanForBridges()
    }

    func endDiscovery() {
        userRequestedScan = false
        guard selectedBridgeID == nil
                || peripheral?.state == .connected
                || peripheral?.state == .connecting else { return }
        central?.stopScan()
        isScanning = false
    }

    func renameBridge(_ id: UUID, to name: String) {
        bridgeStore.rename(id, to: name)
        publishStore()
        if id == selectedBridgeID, isReady {
            statusText = localizedFormat("Підключено · %@", bridgeDisplayName)
        }
    }

    func dismissFirmwareSecurityIssue() {
        firmwareSecurityIssue = nil
    }

    func forgetBridge(_ id: UUID) {
        let wasSelected = selectedBridgeID == id
        if wasSelected { firmwareSecurityIssue = nil }
        bridgeStore.forget(id)
        publishStore()
        discoveredBridges.removeAll { $0.id == id }
        peers.removeValue(forKey: id)
        guard wasSelected else { return }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if let peripheral, peripheral.identifier == id {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
        }
        connectedBridgeID = nil
        resetConnectionState()
        statusText = localized("Вибери ESP-адаптер")
        if isRunning { scanForBridges() }
    }

    private func connectToSelectedBridgeOrScan() {
        guard isRunning else { return }
        guard let central, central.state == .poweredOn else { return }
        guard peripheral?.state != .connecting, peripheral?.state != .connected else { return }

        guard let identifier = selectedBridgeID else {
            statusText = localized("Вибери ESP-адаптер")
            scanForBridges()
            return
        }

        if let remembered = peers[identifier]
            ?? central.retrievePeripherals(withIdentifiers: [identifier]).first {
            peers[identifier] = remembered
            peripheral = remembered
            remembered.delegate = self
            bridgeStore.updateDiscoveredName(remembered.name, for: identifier)
            publishStore()
            statusText = localizedFormat("Bluetooth: підключення до %@…", bridgeDisplayName)
            central.connect(remembered, options: nil)
            if userRequestedScan { scanForBridges() }
            return
        }

        statusText = localizedFormat("Bluetooth: пошук %@…", bridgeDisplayName)
        scanForBridges()
    }

    private func scanForBridges() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt - 1)), 8)
        statusText = localizedFormat("Bluetooth: перепідключення через %d с…", Int(delay))

        let work = DispatchWorkItem { [weak self] in
            self?.connectToSelectedBridgeOrScan()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetConnectionState() {
        isReady = false
        connectedBridgeID = nil
        writeChar = nil
        securityChar = nil
        nameChar = nil
        pendingWrites.removeAll()
        writeWithResponseInFlight = false
        lastSentModifiersMask = 0
        possiblyHeldKeys.removeAll()
    }
}

extension BLEKeyboardBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isRunning else { return }
        switch central.state {
        case .poweredOn:
            connectToSelectedBridgeOrScan()
        case .poweredOff:
            statusText = localized("Bluetooth вимкнено")
            isScanning = false
            peers.removeAll()
            peripheral = nil
            resetConnectionState()
        case .unauthorized:
            statusText = localized("Немає дозволу на Bluetooth")
            isScanning = false
            resetConnectionState()
        case .unsupported:
            statusText = localized("Bluetooth LE не підтримується")
            isScanning = false
            resetConnectionState()
        case .resetting:
            statusText = localized("Bluetooth перезапускається…")
            isScanning = false
            peers.removeAll()
            peripheral = nil
            resetConnectionState()
        case .unknown:
            statusText = localized("Bluetooth: невідомий стан")
            isScanning = false
            resetConnectionState()
        @unknown default:
            statusText = localized("Bluetooth: невідомий стан")
            isScanning = false
            resetConnectionState()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for restored in restoredPeripherals { peers[restored.identifier] = restored }
        guard let selectedBridgeID,
              let restored = restoredPeripherals.first(where: { $0.identifier == selectedBridgeID }) else { return }
        peripheral = restored
        restored.delegate = self
        statusText = localized("Bluetooth: відновлення з’єднання…")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isRunning else { return }
        let id = peripheral.identifier
        let name = advertisedName(for: peripheral, advertisementData: advertisementData)
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let signal = RSSI.intValue == 127 ? nil : RSSI.intValue
        peers[id] = peripheral

        let candidate = DiscoveredESPBridge(id: id, name: name, signal: signal, isConnectable: isConnectable)
        discoveredBridges.removeAll { $0.id == id }
        discoveredBridges.append(candidate)
        discoveredBridges.sort { ($0.signal ?? -200) > ($1.signal ?? -200) }
        if bridgeStore.bridge(id) != nil {
            bridgeStore.updateDiscoveredName(name, for: id)
            publishStore()
        }

        guard id == selectedBridgeID, isConnectable,
              self.peripheral?.state != .connecting,
              self.peripheral?.state != .connected else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        statusText = localizedFormat("Bluetooth: підключення до %@…", bridgeDisplayName)
        if !userRequestedScan {
            central.stopScan()
            isScanning = false
        }
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isRunning else { central.cancelPeripheralConnection(peripheral); return }
        guard peripheral.identifier == selectedBridgeID else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        self.peripheral = peripheral
        let name = discoveredBridges.first(where: { $0.id == peripheral.identifier })?.name
            ?? advertisedName(for: peripheral)
        bridgeStore.connected(peripheral.identifier, fallbackName: name)
        publishStore()
        statusText = localized("Bluetooth: перевірка сервісу…")
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == selectedBridgeID else { return }
        resetConnectionState()
        self.peripheral = nil
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == selectedBridgeID else { return }
        resetConnectionState()
        self.peripheral = nil
        scheduleReconnect()
    }
}

extension BLEKeyboardBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == selectedBridgeID else { return }
        if let error {
            statusText = localizedFormat("Помилка BLE-сервісу: %@", error.localizedDescription)
            scheduleReconnect()
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            statusText = localized("ESP32 не має потрібного BLE-сервісу")
            return
        }
        peripheral.discoverCharacteristics([writeCharUUID, securityCharUUID, nameCharUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == selectedBridgeID else { return }
        if let error {
            statusText = localizedFormat("Помилка BLE-команди: %@", error.localizedDescription)
            scheduleReconnect()
            return
        }

        guard let characteristic = service.characteristics?.first(where: { $0.uuid == writeCharUUID }) else {
            statusText = localized("ESP32 не має каналу команд")
            return
        }
        guard let securityCharacteristic = service.characteristics?.first(where: { $0.uuid == securityCharUUID }) else {
            writeChar = nil
            firmwareSecurityIssue = .unsafeLegacy
            statusText = localized("Незахищена прошивка ESP — онови її")
            return
        }
        writeChar = characteristic
        securityChar = securityCharacteristic
        nameChar = service.characteristics?.first(where: { $0.uuid == nameCharUUID })
        statusText = localized("Bluetooth: захищене сполучення…")
        peripheral.readValue(for: securityCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == selectedBridgeID else { return }
        if characteristic.uuid == nameCharUUID {
            guard error == nil,
                  let name = ESPBridgeNamePayload.decode(characteristic.value) else { return }
            if let index = discoveredBridges.firstIndex(where: { $0.id == peripheral.identifier }) {
                discoveredBridges[index].name = name
            }
            bridgeStore.updateDiscoveredName(name, for: peripheral.identifier)
            publishStore()
            if isReady {
                statusText = localizedFormat("Підключено · %@", bridgeDisplayName)
            }
            return
        }
        guard characteristic.uuid == securityCharUUID else { return }
        if let error {
            isReady = false
            connectedBridgeID = nil
            statusText = localizedFormat(
                "Захищене сполучення не завершено: %@",
                error.localizedDescription
            )
            return
        }
        guard characteristic.value == requiredSecurityCapability else {
            isReady = false
            connectedBridgeID = nil
            writeChar = nil
            firmwareSecurityIssue = .unknownCapability
            statusText = localized("Невідома версія захисту ESP — онови прошивку")
            return
        }

        firmwareSecurityIssue = nil
        connectedBridgeID = peripheral.identifier
        statusText = localizedFormat("Підключено · %@", bridgeDisplayName)
        isReady = true
        if let nameChar { peripheral.readValue(for: nameChar) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainWriteQueue(type: .withoutResponse)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        // This callback exposes CoreBluetooth's cached GAP name. Keep it only
        // as a fallback for migrated entries that have no better name yet.
        guard bridgeStore.bridge(peripheral.identifier)?.advertisedName == nil else { return }
        bridgeStore.updateDiscoveredName(peripheral.name, for: peripheral.identifier)
        publishStore()
        if isReady {
            statusText = localizedFormat("Підключено · %@", bridgeDisplayName)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        writeWithResponseInFlight = false
        if error == nil {
            drainWriteQueue(type: .withResponse)
        }
        finishStopIfDrained()
    }
}
