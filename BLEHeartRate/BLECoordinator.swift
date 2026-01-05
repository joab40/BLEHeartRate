// Version 1.0.14
import Foundation
import Combine
import CoreBluetooth

final class BLECoordinator: NSObject, ObservableObject {

    // MARK: - Public state

    @Published var sensorConfigs: [SensorConfig] = []
    @Published var runtime: [UUID: SensorRuntime] = [:]

    @Published var isScanning: Bool = false
    @Published var isPoweredOn: Bool = false
    @Published var bluetoothText: String = "Bluetooth…"

    @Published var discovered: [DiscoveredSensor] = []

    // MARK: - BLE constants

    private let hrService = CBUUID(string: "180D")
    private let hrMeasurementChar = CBUUID(string: "2A37")

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevelChar = CBUUID(string: "2A19")

    // MARK: - Internals

    private var central: CBCentralManager!

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discoveredMap: [UUID: DiscoveredSensor] = [:]
    private var wantedConnected: Set<UUID> = []

    private struct ReconnectPolicy {
        var attemptCount: Int = 0
        var nextAllowedAt: Date = .distantPast
    }
    private var reconnectPolicy: [UUID: ReconnectPolicy] = [:]

    private var tickTimer: Timer?

    // MARK: - Persistence keys

    /// Current key we will write to
    private let configsKey = "BLEHeartRate.SensorConfigs.v2"

    /// Known legacy keys to try first
    private let legacyConfigKeys: [String] = [
        "BLEHeartRate.SensorConfigs",
        "BLEHeartRate.SensorConfigs.v1",
        "SensorConfigs",
        "sensors",
        "savedSensors"
    ]

    /// Set to true if you want console logs for debugging UserDefaults migration
    private let debugMigrationLogs = true

    // MARK: - Init

    override init() {
        super.init()

        central = CBCentralManager(delegate: self, queue: DispatchQueue(label: "ble.central.queue"))

        loadConfigsWithAutoDetectMigration()
        ensureRuntimeEntries()
        startTick()
    }

    deinit {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Public API

    func startScan() {
        guard isPoweredOn else { return }
        isScanning = true

        DispatchQueue.main.async { [weak self] in
            self?.bluetoothText = "Skannar…"
        }

        let opts: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ]
        central.scanForPeripherals(withServices: [hrService], options: opts)
    }

    func stopScan() {
        isScanning = false
        central.stopScan()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bluetoothText = self.isPoweredOn ? "Bluetooth på" : "Bluetooth av"
        }
    }

    func connect(id: UUID) {
        wantedConnected.insert(id)
        setState(id: id, state: .connecting, text: "Ansluter…")

        if let p = peripherals[id] {
            connectPeripheral(p, reason: "manual connect")
            return
        }

        if let d = discoveredMap[id], let p = d.peripheral {
            peripherals[id] = p
            connectPeripheral(p, reason: "manual connect from discovered")
            return
        }

        startScan()
    }

    func disconnect(id: UUID) {
        wantedConnected.remove(id)
        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }
        setState(id: id, state: .disconnected, text: "Frånkopplad")
    }

    func reconnectAllAuto() {
        for cfg in sensorConfigs where cfg.autoConnect {
            connect(id: cfg.id)
        }
    }

    func removeSensor(id: UUID) {
        sensorConfigs.removeAll { $0.id == id }
        saveConfigs()

        wantedConnected.remove(id)
        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }

        runtime.removeValue(forKey: id)
        discoveredMap.removeValue(forKey: id)
        refreshDiscoveredPublished()
    }

    func upsertSensor(_ cfg: SensorConfig) {
        if let idx = sensorConfigs.firstIndex(where: { $0.id == cfg.id }) {
            sensorConfigs[idx] = cfg
        } else {
            sensorConfigs.append(cfg)
        }
        saveConfigs()
        ensureRuntimeEntries()
    }

    func addDiscovered(id: UUID, name: String? = nil) {
        let display = (name?.isEmpty == false) ? name! : (discoveredMap[id]?.name ?? "Sensor")
        let cfg = SensorConfig.default(id: id, name: display)
        upsertSensor(cfg)
    }

    // MARK: - Tick

    private func startTick() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickTimer?.invalidate()
            self.tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date()

        for cfg in sensorConfigs {
            var rt = runtime[cfg.id] ?? SensorRuntime()

            if let last = rt.lastHRAt {
                let delta = Int(now.timeIntervalSince(last))
                rt.lastSeenSeconds = max(0, delta)
                rt.isStale = delta > 6
            } else {
                rt.lastSeenSeconds = 0
                rt.isStale = false
            }

            runtime[cfg.id] = rt
        }

        for (id, p) in peripherals where p.state == .connected {
            if (runtime[id]?.isStale ?? false) || (runtime[id]?.lastHRAt == nil) {
                p.readRSSI()
            }
        }

        for cfg in sensorConfigs {
            let id = cfg.id
            let rt = runtime[id] ?? SensorRuntime()
            let shouldWant = wantedConnected.contains(id) || cfg.autoConnect
            guard shouldWant else { continue }
            guard rt.state == .disconnected else { continue }
            attemptReconnect(id: id, now: now)
        }
    }

    // MARK: - Stable percent

    private func percentOfMaxStable(hr: Int, maxHR: Int) -> Int {
        guard maxHR > 0 else { return 0 }
        let raw = (Double(hr) * 100.0) / Double(maxHR)
        let p = Int(raw) // trunc/floor
        return max(0, min(100, p))
    }

    // MARK: - Reconnect policy

    private func attemptReconnect(id: UUID, now: Date) {
        var pol = reconnectPolicy[id] ?? ReconnectPolicy()
        if now < pol.nextAllowedAt { return }

        pol.attemptCount += 1

        let delay: TimeInterval
        switch pol.attemptCount {
        case 1: delay = 0.2
        case 2: delay = 0.5
        case 3: delay = 1.0
        case 4: delay = 2.0
        default: delay = 3.0
        }

        pol.nextAllowedAt = now.addingTimeInterval(delay)
        reconnectPolicy[id] = pol

        if let p = peripherals[id] {
            connectPeripheral(p, reason: "auto reconnect")
        } else {
            startScan()
        }
    }

    private func resetReconnectPolicy(id: UUID) {
        reconnectPolicy[id] = ReconnectPolicy(attemptCount: 0, nextAllowedAt: .distantPast)
    }

    // MARK: - Persistence (AUTO-DETECT + MIGRATION)

    private func loadConfigsWithAutoDetectMigration() {
        // 1) Try current key
        if let decoded = decodeConfigs(forKey: configsKey) {
            sensorConfigs = decoded
            if debugMigrationLogs {
                print("✅ Loaded SensorConfigs from current key:", configsKey, "count:", decoded.count)
            }
            return
        }

        // 2) Try known legacy keys
        for key in legacyConfigKeys {
            if let decoded = decodeConfigs(forKey: key) {
                sensorConfigs = decoded
                saveConfigs() // migrate to current key
                if debugMigrationLogs {
                    print("✅ Migrated SensorConfigs from legacy key:", key, "→", configsKey, "count:", decoded.count)
                }
                return
            }
        }

        // 3) Heuristic scan: try decode from ANY Data entry in UserDefaults
        let all = UserDefaults.standard.dictionaryRepresentation()

        if debugMigrationLogs {
            print("🔎 Heuristic scan UserDefaults keys:", all.keys.count)
        }

        for (key, value) in all {
            guard let data = value as? Data else { continue }

            guard let decoded = try? JSONDecoder().decode([SensorConfig].self, from: data) else { continue }
            guard isPlausibleConfigs(decoded) else { continue }

            sensorConfigs = decoded
            saveConfigs() // migrate to current key
            if debugMigrationLogs {
                print("✅ Auto-detected SensorConfigs in key:", key, "→", configsKey, "count:", decoded.count)
            }
            return
        }

        // If still nothing: likely new bundle id / new app sandbox
        sensorConfigs = []
        if debugMigrationLogs {
            print("⚠️ No saved sensors found in UserDefaults. If you changed Bundle Identifier, old data is in the old app sandbox.")
        }
    }

    private func decodeConfigs(forKey key: String) -> [SensorConfig]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        guard let decoded = try? JSONDecoder().decode([SensorConfig].self, from: data) else { return nil }
        return decoded
    }

    private func isPlausibleConfigs(_ arr: [SensorConfig]) -> Bool {
        guard !arr.isEmpty else { return false }
        // sanity checks to avoid false positives
        for c in arr {
            if c.maxHR < 60 || c.maxHR > 240 { return false }
            if c.avatar.isEmpty { return false }
            if c.displayName.isEmpty { return false }
        }
        return true
    }

    private func saveConfigs() {
        do {
            let data = try JSONEncoder().encode(sensorConfigs)
            UserDefaults.standard.set(data, forKey: configsKey)
        } catch {
            // ignore
        }
    }

    private func ensureRuntimeEntries() {
        for cfg in sensorConfigs {
            if runtime[cfg.id] == nil {
                runtime[cfg.id] = SensorRuntime()
            }
        }
    }

    // MARK: - Helpers

    private func setState(id: UUID, state: ConnectionState, text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var rt = self.runtime[id] ?? SensorRuntime()
            rt.state = state
            rt.statusText = text
            self.runtime[id] = rt
        }
    }

    private func updateRSSI(id: UUID, rssi: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var rt = self.runtime[id] ?? SensorRuntime()
            rt.rssi = rssi
            self.runtime[id] = rt
        }
    }

    private func updateBattery(id: UUID, battery: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var rt = self.runtime[id] ?? SensorRuntime()
            rt.battery = battery
            self.runtime[id] = rt
        }
    }

    private func updateHR(id: UUID, hr: Int, rrMs: Int?) {
        let maxHR = sensorConfigs.first(where: { $0.id == id })?.maxHR ?? 190
        let percent = percentOfMaxStable(hr: hr, maxHR: maxHR)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var rt = self.runtime[id] ?? SensorRuntime()
            rt.hr = hr
            rt.rrMs = rrMs
            rt.lastHRAt = Date()
            rt.isStale = false
            rt.percentOfMax = percent

            rt.percentHistory.append(percent)
            if rt.percentHistory.count > 120 {
                rt.percentHistory.removeFirst(rt.percentHistory.count - 120)
            }

            self.runtime[id] = rt
        }
    }

    private func connectPeripheral(_ p: CBPeripheral, reason: String) {
        p.delegate = self
        setState(id: p.identifier, state: .connecting, text: "Ansluter…")

        central.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    private func refreshDiscoveredPublished() {
        let arr = discoveredMap.values.sorted {
            let a = $0.rssi ?? -999
            let b = $1.rssi ?? -999
            if a != b { return a > b }
            return $0.name < $1.name
        }

        DispatchQueue.main.async { [weak self] in
            self?.discovered = arr
        }
    }
}

// MARK: - Models

struct DiscoveredSensor: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int?
    let lastSeen: Date
    let peripheral: CBPeripheral?
}

// MARK: - CBCentralManagerDelegate

extension BLECoordinator: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let powered = (central.state == .poweredOn)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPoweredOn = powered
            switch central.state {
            case .poweredOn:
                self.bluetoothText = self.isScanning ? "Skannar…" : "Bluetooth på"
            case .poweredOff:
                self.bluetoothText = "Bluetooth av"
            case .unauthorized:
                self.bluetoothText = "Bluetooth ej tillåtet"
            case .unsupported:
                self.bluetoothText = "Bluetooth stöds ej"
            default:
                self.bluetoothText = "Bluetooth…"
            }
        }

        if powered {
            reconnectAllAuto()
        } else {
            stopScan()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        peripherals[id] = peripheral

        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Sensor"

        let d = DiscoveredSensor(
            id: id,
            name: name,
            rssi: RSSI.intValue,
            lastSeen: Date(),
            peripheral: peripheral
        )
        discoveredMap[id] = d
        refreshDiscoveredPublished()

        if sensorConfigs.contains(where: { $0.id == id }) {
            if (runtime[id]?.state ?? .disconnected) == .disconnected {
                setState(id: id, state: .scanning, text: "Hittad • redo")
            }
        }

        let shouldWant = wantedConnected.contains(id) || sensorConfigs.first(where: { $0.id == id })?.autoConnect == true
        if shouldWant {
            let now = Date()
            let pol = reconnectPolicy[id] ?? ReconnectPolicy()
            if now >= pol.nextAllowedAt {
                connectPeripheral(peripheral, reason: "discovered wanted")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetReconnectPolicy(id: peripheral.identifier)
        setState(id: peripheral.identifier, state: .connected, text: "Ansluten")

        peripheral.delegate = self
        peripheral.discoverServices([hrService, batteryService])
        peripheral.readRSSI()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        setState(id: peripheral.identifier, state: .disconnected, text: "Misslyckades")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        setState(id: peripheral.identifier, state: .disconnected, text: "Frånkopplad")
    }
}

// MARK: - CBPeripheralDelegate

extension BLECoordinator: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        updateRSSI(id: peripheral.identifier, rssi: RSSI.intValue)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        guard let services = peripheral.services else { return }

        for s in services {
            if s.uuid == hrService {
                peripheral.discoverCharacteristics([hrMeasurementChar], for: s)
            } else if s.uuid == batteryService {
                peripheral.discoverCharacteristics([batteryLevelChar], for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { return }
        guard let chars = service.characteristics else { return }

        for c in chars {
            if service.uuid == hrService && c.uuid == hrMeasurementChar {
                peripheral.setNotifyValue(true, for: c)
            }

            if service.uuid == batteryService && c.uuid == batteryLevelChar {
                peripheral.readValue(for: c)
                if c.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return }
        guard let data = characteristic.value else { return }

        if characteristic.uuid == hrMeasurementChar {
            let parsed = parseHeartRateMeasurement(data)
            updateHR(id: peripheral.identifier, hr: parsed.hr, rrMs: parsed.rrMs)
            peripheral.readRSSI()
            return
        }

        if characteristic.uuid == batteryLevelChar, let b = data.first {
            updateBattery(id: peripheral.identifier, battery: Int(b))
            return
        }
    }

    private func parseHeartRateMeasurement(_ data: Data) -> (hr: Int, rrMs: Int?) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return (0, nil) }

        let flags = bytes[0]
        let isUInt16 = (flags & 0x01) != 0
        let rrPresent = (flags & 0x10) != 0

        var idx = 1
        let hr: Int

        if isUInt16 {
            guard bytes.count >= idx + 2 else { return (0, nil) }
            hr = Int(UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8))
            idx += 2
        } else {
            guard bytes.count > idx else { return (0, nil) }
            hr = Int(bytes[idx])
            idx += 1
        }

        var rrMs: Int? = nil
        if rrPresent, bytes.count >= idx + 2 {
            let rr1024 = Int(UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8))
            rrMs = Int((Double(rr1024) / 1024.0) * 1000.0)
        }

        return (hr, rrMs)
    }
}
