// Tag 1.0.2

import Foundation
import CoreBluetooth
import Combine

@MainActor
final class BLECoordinator: NSObject, ObservableObject {

    // MARK: Published UI state
    @Published var bluetoothText: String = "Initierar…"
    @Published var isPoweredOn: Bool = false
    @Published var isScanning: Bool = false

    @Published var sensorConfigs: [SensorConfig] = [] {
        didSet { Persistence.saveSensors(sensorConfigs) }
    }

    /// Runtime per sensor (UI läser härifrån)
    @Published private(set) var runtime: [UUID: SensorRuntime] = [:]

    /// Discovered peripherals under scan (för “lägg till”)
    @Published var discovered: [UUID: (name: String, rssi: Int)] = [:]

    // MARK: CoreBluetooth
    private var central: CBCentralManager!

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var hrChar: [UUID: CBCharacteristic] = [:]
    private var batteryChar: [UUID: CBCharacteristic] = [:]

    // MARK: Desired connections (minskar reconnect-tryck)
    /// Set av sensorer vi vill ha uppkopplade (autoConnect + manuellt connect)
    private var desiredConnections: Set<UUID> = []

    // MARK: Reconnect/backoff (ultra snabb reacquire)
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]

    // Anti-thrash
    private var lastConnectAttemptAt: [UUID: Date] = [:]
    private let minConnectAttemptInterval: TimeInterval = 0.8

    // Backoff cap (sek): 0,1,2,2,2...
    private let reconnectDelayCapSeconds: Int = 2

    // Timers
    private var tickTask: Task<Void, Never>?
    private var rssiTask: Task<Void, Never>?
    private var batteryTask: Task<Void, Never>?

    // Stale UI-only (ingen reconnect)
    private let staleAfterSeconds: Int = 10

    // Sparkline history
    private let maxHistoryCount: Int = 240 // ~4 min vid ~1Hz

    // Scan mode: auto (för reacquire) eller manual (användaren trycker Scan)
    private enum ScanMode { case off, auto, manual }
    private var scanMode: ScanMode = .off

    override init() {
        super.init()

        sensorConfigs = Persistence.loadSensors()
        central = CBCentralManager(delegate: self, queue: nil)

        // init runtime entries + desired connections för autoConnect
        for cfg in sensorConfigs {
            ensureRuntimeExists(for: cfg.id)
            if cfg.autoConnect {
                desiredConnections.insert(cfg.id)
            }
        }

        startTicking()
        startRSSIPolling()
        startBatteryPolling()
    }

    deinit {
        tickTask?.cancel()
        rssiTask?.cancel()
        batteryTask?.cancel()
        for (_, t) in reconnectTasks { t.cancel() }
    }

    // MARK: Public actions

    /// Manuell scan (dashboard-knapp / scanner-sheet)
    func startScan() {
        guard isPoweredOn else { return }
        scanMode = .manual
        startCentralScan(aggressive: true)
    }

    func stopScan() {
        scanMode = .off
        central.stopScan()
        isScanning = false
    }

    func addOrUpdateConfigFromDiscovery(id: UUID, name: String) {
        if let idx = sensorConfigs.firstIndex(where: { $0.id == id }) {
            if sensorConfigs[idx].displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || sensorConfigs[idx].displayName == "Sensor" {
                sensorConfigs[idx].displayName = name
            }
        } else {
            sensorConfigs.append(.default(id: id, name: name))
        }

        ensureRuntimeExists(for: id)
    }

    func updateConfig(_ cfg: SensorConfig) {
        if let idx = sensorConfigs.firstIndex(where: { $0.id == cfg.id }) {
            sensorConfigs[idx] = cfg
        } else {
            sensorConfigs.append(cfg)
        }

        ensureRuntimeExists(for: cfg.id)

        // Desired connections enligt autoConnect
        if cfg.autoConnect {
            desiredConnections.insert(cfg.id)
            connect(id: cfg.id)
        } else {
            // Om användaren slår av autoConnect så slutar vi jaga den automatiskt
            desiredConnections.remove(cfg.id)
        }

        ensureAutoScanIfNeeded()
    }

    func removeSensor(id: UUID) {
        // sluta vilja ha den uppkopplad
        desiredConnections.remove(id)
        cancelReconnect(id: id)

        // disconnect om den är ansluten
        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }

        // rensa caches
        peripherals[id] = nil
        hrChar[id] = nil
        batteryChar[id] = nil

        // ta bort från listor
        sensorConfigs.removeAll { $0.id == id }
        runtime[id] = nil

        ensureAutoScanIfNeeded()
    }

    /// Manuell connect (eller autoconnect kick)
    func connect(id: UUID) {
        ensureRuntimeExists(for: id)

        // Markera att vi vill ha uppkoppling
        desiredConnections.insert(id)

        // anti-thrash
        let now = Date()
        if let last = lastConnectAttemptAt[id], now.timeIntervalSince(last) < minConnectAttemptInterval {
            ensureAutoScanIfNeeded()
            return
        }
        lastConnectAttemptAt[id] = now

        // already connecting/connected?
        if runtime[id]?.state == .connecting || runtime[id]?.state == .connected {
            ensureAutoScanIfNeeded()
            return
        }

        // hitta peripheral via cache / retrieve
        let p = peripherals[id] ?? retrieveKnownPeripheral(id: id)

        guard let peripheral = p else {
            setRuntime(id: id) { r in
                r.state = .connecting
                r.statusText = "Väntar på upptäckt…"
            }
            // se till att vi scannar så fort den kommer upp ur vattnet
            ensureAutoScanIfNeeded()
            scheduleReconnect(id: id, immediate: true)
            return
        }

        setRuntime(id: id) { r in
            r.state = .connecting
            r.statusText = "Ansluter…"
        }

        central.connect(peripheral, options: nil)
        ensureAutoScanIfNeeded()
    }

    /// Manuell disconnect (stoppar “jakt”)
    func disconnect(id: UUID) {
        desiredConnections.remove(id)
        cancelReconnect(id: id)

        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }

        setRuntime(id: id) { r in
            r.state = .disconnected
            r.statusText = "Frånkopplad"
        }

        ensureAutoScanIfNeeded()
    }

    /// Reconnect alla som har autoConnect (och lägg dem i desired)
    func reconnectAllAuto() {
        for cfg in sensorConfigs where cfg.autoConnect {
            desiredConnections.insert(cfg.id)
            connect(id: cfg.id)
        }
        ensureAutoScanIfNeeded()
    }

    // MARK: Scanning policy

    private func startCentralScan(aggressive: Bool) {
        guard isPoweredOn else { return }
        discovered.removeAll()

        // Aggressiv scan: allow duplicates för snabbare reacquire/uppdatering
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: aggressive
        ])

        isScanning = true
    }

    /// Auto-scan endast när någon desired sensor inte är connected
    private func ensureAutoScanIfNeeded() {
        guard isPoweredOn else { return }

        // manual scan har prioritet
        if scanMode == .manual {
            return
        }

        // Behöver vi scanna?
        let needsScan = desiredConnections.contains { id in
            let st = runtime[id]?.state ?? .disconnected
            return st != .connected
        }

        if needsScan {
            if scanMode != .auto || !isScanning {
                scanMode = .auto
                startCentralScan(aggressive: true)
            }
        } else {
            if scanMode == .auto && isScanning {
                central.stopScan()
                isScanning = false
            }
            scanMode = .off
        }
    }

    // MARK: Runtime helpers

    private func ensureRuntimeExists(for id: UUID) {
        if runtime[id] == nil {
            runtime[id] = SensorRuntime()
        }
    }

    private func setRuntime(id: UUID, mutate: (inout SensorRuntime) -> Void) {
        var r = runtime[id] ?? SensorRuntime()
        mutate(&r)

        // percent-of-max
        if let bpm = r.hr, let cfg = sensorConfigs.first(where: { $0.id == id }) {
            let pct = Int((Double(bpm) / Double(max(cfg.maxHR, 1))) * 100.0)
            r.percentOfMax = max(0, min(200, pct))
        } else {
            r.percentOfMax = nil
        }

        runtime[id] = r
    }

    private func retrieveKnownPeripheral(id: UUID) -> CBPeripheral? {
        let found = central.retrievePeripherals(withIdentifiers: [id]).first
        if let found { peripherals[id] = found }
        return found
    }

    // MARK: Reconnect scheduling

    private func cancelReconnect(id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        reconnectAttempts[id] = 0
    }

    private func scheduleReconnect(id: UUID, immediate: Bool) {
        // reconnect endast om vi faktiskt vill ha den ansluten
        guard desiredConnections.contains(id) else { return }

        reconnectTasks[id]?.cancel()

        let attempt = (reconnectAttempts[id] ?? 0) + 1
        reconnectAttempts[id] = attempt

        let delaySeconds: Int
        if immediate {
            delaySeconds = 0
        } else {
            // 1,2,2,2...
            delaySeconds = min(Int(pow(2.0, Double(attempt - 1))), reconnectDelayCapSeconds)
        }

        reconnectTasks[id] = Task { [weak self] in
            guard let self else { return }

            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            }
            if Task.isCancelled { return }

            // Om vi inte längre vill ha anslutning, sluta
            guard self.desiredConnections.contains(id) else { return }

            // redan connected?
            if self.runtime[id]?.state == .connected { return }

            self.ensureAutoScanIfNeeded()
            self.connect(id: id)

            // fortsätt tills vi är tillbaka
            if self.runtime[id]?.state != .connected {
                self.scheduleReconnect(id: id, immediate: false)
            }
        }
    }

    // MARK: Timers

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.updateLastSeenAndStale()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func updateLastSeenAndStale() {
        let now = Date()

        for cfg in sensorConfigs {
            let id = cfg.id
            guard runtime[id] != nil else { continue }

            setRuntime(id: id) { r in
                if let t = r.lastHRAt {
                    let sec = Int(now.timeIntervalSince(t))
                    r.lastSeenSeconds = max(0, sec)
                    r.isStale = sec >= staleAfterSeconds

                    // stale är UI-only – ingen reconnect
                    if r.state == .connected {
                        r.statusText = r.isStale ? "Signal tappad (under vatten?)" : "Tar emot data"
                    }
                } else {
                    r.lastSeenSeconds = 0
                    r.isStale = false
                    if r.state == .connected {
                        r.statusText = "Ansluten (ingen data än)"
                    }
                }
            }
        }
    }

    private func startRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                for id in self.desiredConnections {
                    if self.runtime[id]?.state == .connected, let p = self.peripherals[id] {
                        p.readRSSI()
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func startBatteryPolling() {
        batteryTask?.cancel()
        batteryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                for id in self.desiredConnections {
                    if self.runtime[id]?.state == .connected,
                       let p = self.peripherals[id],
                       let c = self.batteryChar[id] {
                        // läsa batteri ibland (t.ex. var 60s)
                        p.readValue(for: c)
                    }
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
            }
        }
    }

    private func appendPercentHistory(id: UUID) {
        setRuntime(id: id) { r in
            if let pct = r.percentOfMax {
                r.percentHistory.append(pct)
                if r.percentHistory.count > maxHistoryCount {
                    r.percentHistory.removeFirst(r.percentHistory.count - maxHistoryCount)
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLECoordinator: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothText = "Bluetooth: På"
            isPoweredOn = true

            // auto-connect: lägg autoConnect-sensorer i desired
            for cfg in sensorConfigs where cfg.autoConnect {
                desiredConnections.insert(cfg.id)
            }

            reconnectAllAuto()
            ensureAutoScanIfNeeded()

        case .poweredOff:
            bluetoothText = "Bluetooth: Av"
            isPoweredOn = false

            if isScanning {
                central.stopScan()
                isScanning = false
            }
            scanMode = .off

            for cfg in sensorConfigs {
                setRuntime(id: cfg.id) { r in
                    r.state = .disconnected
                    r.statusText = "Bluetooth av"
                }
            }

        case .unauthorized:
            bluetoothText = "Bluetooth: Ingen behörighet"
            isPoweredOn = false

        case .unsupported:
            bluetoothText = "Bluetooth: Stöds ej"
            isPoweredOn = false

        case .resetting:
            bluetoothText = "Bluetooth: Återställs…"

        case .unknown:
            bluetoothText = "Bluetooth: Okänd"

        @unknown default:
            bluetoothText = "Bluetooth: Okänd"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        let id = peripheral.identifier
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Okänd"

        peripherals[id] = peripheral
        discovered[id] = (name: name, rssi: RSSI.intValue)

        // Om vi vill ha uppkoppling till den här sensorn: anslut direkt när den syns
        if desiredConnections.contains(id) {
            ensureRuntimeExists(for: id)
            let st = runtime[id]?.state ?? .disconnected
            if st != .connected && st != .connecting {
                connect(id: id)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        peripherals[id] = peripheral

        cancelReconnect(id: id)

        setRuntime(id: id) { r in
            r.state = .connected
            r.statusText = "Ansluten"
        }

        peripheral.delegate = self
        peripheral.discoverServices([BLEConstants.heartRateService, BLEConstants.batteryService])

        ensureAutoScanIfNeeded()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let id = peripheral.identifier

        setRuntime(id: id) { r in
            r.state = .disconnected
            r.statusText = "Kunde inte ansluta"
        }

        ensureAutoScanIfNeeded()
        scheduleReconnect(id: id, immediate: false)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let id = peripheral.identifier

        hrChar[id] = nil
        batteryChar[id] = nil

        setRuntime(id: id) { r in
            r.state = .disconnected
            r.statusText = desiredConnections.contains(id) ? "Frånkopplad (återansluter…)" : "Frånkopplad"
        }

        // Pool-case: disconnect är normalt. Reconnect bara om vi faktiskt vill ha den.
        if desiredConnections.contains(id) {
            ensureAutoScanIfNeeded()
            scheduleReconnect(id: id, immediate: true)
        } else {
            ensureAutoScanIfNeeded()
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLECoordinator: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        guard error == nil else {
            setRuntime(id: id) { r in r.statusText = "Service-fel" }
            return
        }
        guard let services = peripheral.services else { return }

        for s in services {
            if s.uuid == BLEConstants.heartRateService {
                peripheral.discoverCharacteristics([BLEConstants.heartRateMeasurement], for: s)
            }
            if s.uuid == BLEConstants.batteryService {
                peripheral.discoverCharacteristics([BLEConstants.batteryLevel], for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let id = peripheral.identifier
        guard error == nil else { return }
        guard let chars = service.characteristics else { return }

        for c in chars {
            if c.uuid == BLEConstants.heartRateMeasurement {
                hrChar[id] = c
                setRuntime(id: id) { r in r.statusText = "Prenumererar HR…" }
                peripheral.setNotifyValue(true, for: c)
            }

            if c.uuid == BLEConstants.batteryLevel {
                batteryChar[id] = c
                // Läs direkt vid connect
                peripheral.readValue(for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        let id = peripheral.identifier
        guard error == nil else { return }
        if characteristic.uuid == BLEConstants.heartRateMeasurement, characteristic.isNotifying {
            setRuntime(id: id) { r in r.statusText = "Tar emot data" }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let id = peripheral.identifier
        guard error == nil else { return }
        guard let data = characteristic.value else { return }

        if characteristic.uuid == BLEConstants.heartRateMeasurement {
            if let sample = HeartRateParser.parse(data) {
                setRuntime(id: id) { r in
                    r.hr = sample.bpm
                    r.rrMs = sample.rrMs
                    r.lastHRAt = Date()
                    r.statusText = "Tar emot data"
                }
                appendPercentHistory(id: id)
            }
        } else if characteristic.uuid == BLEConstants.batteryLevel {
            let bytes = [UInt8](data)
            if let v = bytes.first {
                setRuntime(id: id) { r in
                    r.battery = Int(v)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didReadRSSI RSSI: NSNumber,
                    error: Error?) {
        guard error == nil else { return }
        let id = peripheral.identifier
        setRuntime(id: id) { r in
            r.rssi = RSSI.intValue
        }
    }
}
