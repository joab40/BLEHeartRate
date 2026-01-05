
// Version 1.0.23
// NOTE (Pool/BLE strategy):
// - Undvik att kalla readRSSI() på varje HR-notification: det kan störa HR-notify-flödet när många sensorer kör samtidigt.
// - Läs RSSI throttlat (t.ex. max 1 gång/sek per sensor, och extra vid “stale”) för stabilare och snabbare HR-uppdateringar.
// - Använd en “stale watchdog”: om en sensor är .connected men inte skickat HR på X sek (t.ex. 12s),
//   forcera reconnect (cancelPeripheralConnection) eftersom “silent links” ofta uppstår när sensorn är under vatten.
// - Lägg en kort holdoff efter hard reset (t.ex. 0.7s) för att undvika reconnect-loop när sensorn precis doppar/kommer upp.
// - Reconnect backoff ska vara aggressiv tidigt (0–1.5s) för att fånga upp signal direkt när sensorn kommer upp över ytan.
// - Vid didDiscover för en “wanted” sensor: om den är disconnected/stale → prioritera reconnect, men respektera holdoff.
// NOTE (Scanning):
// - Auto-scan kan vara HR-only (withServices: [180D]) för effektivitet.
// - Manuell scan i SensorsView bör vara “broad scan” (withServices: nil) för att hitta nya enheter som inte alltid annonserar 180D.

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

    // MARK: - Scan control (Auto vs manual off)

    enum ScanMode: Equatable {
        case auto
        case manualOff
    }

    @Published private(set) var scanMode: ScanMode = .auto

    // MARK: - Scan scope (HR-only vs broad)

    private enum ScanScope: Equatable {
        case hrOnly
        case broad
    }

    private var scanScope: ScanScope = .hrOnly

    // MARK: - BLE constants

    private let hrService = CBUUID(string: "180D")
    private let hrMeasurementChar = CBUUID(string: "2A37")

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevelChar = CBUUID(string: "2A19")

    // MARK: - History policy (2h + 1Hz for graph)

    private let historySamplePeriod: TimeInterval = 1.0       // max 1 punkt/sek i grafen
    private let historyMaxSamples: Int = 2 * 60 * 60          // 2h @ 1Hz
    private var historyLastSampleAt: [UUID: Date] = [:]       // per sensor

    // MARK: - RSSI policy (throttled)

    private let minRSSIInterval: TimeInterval = 1.0           // max 1 RSSI-read/sek per sensor
    private var lastRSSIReadAt: [UUID: Date] = [:]

    // MARK: - Pool watchdog (connected-but-silent)

    private let staleSoftSeconds: Int = 6                     // UI “stale”
    private let staleHardResetSeconds: Int = 12               // hård reset (pool)

    // Holdoff efter hard reset (undvik reconnect-loop + ge sensorn tid att boota/annonsera)
    private let postHardResetHoldoffSeconds: TimeInterval = 0.7
    private var lastHardResetAt: [UUID: Date] = [:]

    // Anti-spam: begränsa hur ofta vi försöker connecta (även om många events triggar)
    private let minConnectAttemptInterval: TimeInterval = 0.8
    private var lastConnectAttemptAt: [UUID: Date] = [:]

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

    private let configsKey = "BLEHeartRate.SensorConfigs.v2"
    private let legacyConfigKeys: [String] = [
        "BLEHeartRate.SensorConfigs",
        "BLEHeartRate.SensorConfigs.v1",
        "SensorConfigs",
        "sensors",
        "savedSensors"
    ]

    private let debugMigrationLogs = false

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

    // MARK: - Public API (Views)

    /// User pressed Scan in SensorsView → enable auto mode and broad scan
    func userStartScanning() {
        scanMode = .auto
        startScan(scope: .broad)
    }

    /// User pressed Stop in SensorsView → manual override OFF
    func userStopScanning() {
        scanMode = .manualOff
        stopScan()
    }

    /// Auto/Coordinator calls this when it needs to scan (respects manualOff) → HR-only
    private func startScanIfAllowed() {
        guard scanMode == .auto else { return }
        startScan(scope: .hrOnly)
    }

    private func startScan(scope: ScanScope) {
        guard isPoweredOn else { return }

        // Om vi redan skannar men i "fel scope" → restart scan med nya parametrar
        if isScanning, scanScope != scope {
            central.stopScan()
            isScanning = false
        }

        guard !isScanning else { return }

        scanScope = scope
        isScanning = true

        DispatchQueue.main.async { [weak self] in
            self?.bluetoothText = "Skannar…"
        }

        let opts: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ]

        // ✅ HR-only scan för auto, broad scan för manuell discover
        switch scope {
        case .hrOnly:
            central.scanForPeripherals(withServices: [hrService], options: opts)
        case .broad:
            central.scanForPeripherals(withServices: nil, options: opts)
        }
    }

    func stopScan() {
        guard isScanning else { return }
        isScanning = false
        central.stopScan()
        scanScope = .hrOnly

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bluetoothText = self.isPoweredOn ? "Bluetooth på" : "Bluetooth av"
        }
    }

    func connect(id: UUID) {
        wantedConnected.insert(id)
        setState(id: id, state: .connecting, text: "Ansluter…")

        if let p = peripherals[id] {
            connectPeripheralIfEligible(p, id: id, now: Date(), reason: "manual connect")
            return
        }

        if let d = discoveredMap[id], let p = d.peripheral {
            peripherals[id] = p
            connectPeripheralIfEligible(p, id: id, now: Date(), reason: "manual connect from discovered")
            return
        }

        // No peripheral handle yet -> scan (if allowed)
        startScanIfAllowed()
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
        peripherals.removeValue(forKey: id)
        reconnectPolicy.removeValue(forKey: id)
        historyLastSampleAt.removeValue(forKey: id)
        lastRSSIReadAt.removeValue(forKey: id)
        lastHardResetAt.removeValue(forKey: id)
        lastConnectAttemptAt.removeValue(forKey: id)

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

        // Update stale/seen + watchdog
        for cfg in sensorConfigs {
            let id = cfg.id
            var rt = runtime[id] ?? SensorRuntime()

            if let last = rt.lastHRAt {
                let delta = Int(now.timeIntervalSince(last))
                rt.lastSeenSeconds = max(0, delta)
                rt.isStale = delta > staleSoftSeconds
            } else {
                rt.lastSeenSeconds = 0
                rt.isStale = false
            }

            runtime[id] = rt

            // Hard watchdog: connected men tyst länge → forcera reconnect (pool-case)
            if rt.state == .connected, rt.lastSeenSeconds >= staleHardResetSeconds {
                // Respektera holdoff: om vi precis hard-resettat, vänta
                if let lastHR = lastHardResetAt[id], now.timeIntervalSince(lastHR) < postHardResetHoldoffSeconds {
                    continue
                }

                if let p = peripherals[id], p.state == .connected {
                    lastHardResetAt[id] = now

                    // Lägg holdoff även i reconnect-policy så auto-reconnect inte hugger direkt
                    reconnectPolicy[id] = ReconnectPolicy(
                        attemptCount: 0,
                        nextAllowedAt: now.addingTimeInterval(postHardResetHoldoffSeconds)
                    )

                    central.cancelPeripheralConnection(p)
                    setState(id: id, state: .disconnected, text: "Signal tappad • reconnect")
                }
            }
        }

        // Throttlad RSSI
        for (id, p) in peripherals where p.state == .connected {
            readRSSIIfAllowed(id: id, peripheral: p, now: now)
        }

        // Auto-reconnect
        var anyAutoNeedsHelp = false

        for cfg in sensorConfigs {
            let id = cfg.id
            let rt = runtime[id] ?? SensorRuntime()
            let shouldWant = wantedConnected.contains(id) || cfg.autoConnect
            guard shouldWant else { continue }

            if rt.state == .disconnected {
                attemptReconnect(id: id, now: now)
                if peripherals[id] == nil {
                    anyAutoNeedsHelp = true
                }
            }
        }

        if anyAutoNeedsHelp && scanMode == .auto && isPoweredOn && !isScanning {
            startScan(scope: .hrOnly)
        }
    }

    private func readRSSIIfAllowed(id: UUID, peripheral: CBPeripheral, now: Date) {
        if let last = lastRSSIReadAt[id], now.timeIntervalSince(last) < minRSSIInterval {
            return
        }
        lastRSSIReadAt[id] = now
        peripheral.readRSSI()
    }

    // MARK: - Stable percent

    private func percentOfMaxStable(hr: Int, maxHR: Int) -> Int {
        guard maxHR > 0 else { return 0 }
        let raw = (Double(hr) * 100.0) / Double(maxHR)
        let p = Int(raw)
        return max(0, min(100, p))
    }

    // MARK: - Reconnect policy

    private func attemptReconnect(id: UUID, now: Date) {
        // Om vi är i post-hard-reset holdoff, gör inget (låter sensorn boota/annonsera)
        if isInPostHardResetHoldoff(id: id, now: now) { return }

        var pol = reconnectPolicy[id] ?? ReconnectPolicy()
        if now < pol.nextAllowedAt { return }

        pol.attemptCount += 1

        // Aggressiv tidigt (pool)
        let delay: TimeInterval
        switch pol.attemptCount {
        case 1: delay = 0.0
        case 2: delay = 0.2
        case 3: delay = 0.5
        case 4: delay = 1.0
        case 5: delay = 1.5
        default: delay = 2.0
        }

        pol.nextAllowedAt = now.addingTimeInterval(delay)
        reconnectPolicy[id] = pol

        if let p = peripherals[id] {
            if !canAttemptConnectNow(id: id, peripheral: p, now: now) { return }
            connectPeripheralIfEligible(p, id: id, now: now, reason: "auto reconnect")
        } else {
            startScanIfAllowed()
        }
    }

    private func resetReconnectPolicy(id: UUID) {
        reconnectPolicy[id] = ReconnectPolicy(attemptCount: 0, nextAllowedAt: .distantPast)
    }

    // MARK: - Connect gating (stable)

    private func isInPostHardResetHoldoff(id: UUID, now: Date) -> Bool {
        guard let last = lastHardResetAt[id] else { return false }
        return now.timeIntervalSince(last) < postHardResetHoldoffSeconds
    }

    private func canAttemptConnectNow(id: UUID, peripheral: CBPeripheral, now: Date) -> Bool {
        if peripheral.state == .connecting || peripheral.state == .connected { return false }
        if isInPostHardResetHoldoff(id: id, now: now) { return false }

        if let last = lastConnectAttemptAt[id], now.timeIntervalSince(last) < minConnectAttemptInterval {
            return false
        }
        return true
    }

    private func connectPeripheralIfEligible(_ p: CBPeripheral,
                                             id: UUID,
                                             now: Date,
                                             reason: String) {
        guard canAttemptConnectNow(id: id, peripheral: p, now: now) else { return }

        // Registrera connect-försök direkt (anti-spam)
        lastConnectAttemptAt[id] = now

        connectPeripheral(p, reason: reason)
    }

    // MARK: - Bootstrap known peripherals (best practice)

    private func bootstrapKnownPeripheralsAndConnectAuto() {
        guard isPoweredOn else { return }
        let ids = sensorConfigs.map(\.id)
        guard !ids.isEmpty else { return }

        let retrieved = central.retrievePeripherals(withIdentifiers: ids)
        for p in retrieved {
            peripherals[p.identifier] = p
        }

        let connected = central.retrieveConnectedPeripherals(withServices: [hrService])
        for p in connected {
            peripherals[p.identifier] = p
        }

        let now = Date()
        for cfg in sensorConfigs where cfg.autoConnect {
            if let p = peripherals[cfg.id] {
                connectPeripheralIfEligible(p, id: cfg.id, now: now, reason: "bootstrap autoConnect")
            }
        }

        let anyMissing = sensorConfigs.contains { $0.autoConnect && peripherals[$0.id] == nil }
        if anyMissing {
            startScanIfAllowed()
        }
    }

    // MARK: - Persistence (AUTO-DETECT + MIGRATION)

    private func loadConfigsWithAutoDetectMigration() {
        if let decoded = decodeConfigs(forKey: configsKey) {
            sensorConfigs = decoded
            if debugMigrationLogs { print("✅ Loaded current key:", configsKey, decoded.count) }
            return
        }

        for key in legacyConfigKeys {
            if let decoded = decodeConfigs(forKey: key) {
                sensorConfigs = decoded
                saveConfigs()
                if debugMigrationLogs { print("✅ Migrated legacy key:", key, decoded.count) }
                return
            }
        }

        let all = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in all {
            guard let data = value as? Data else { continue }
            guard let decoded = try? JSONDecoder().decode([SensorConfig].self, from: data) else { continue }
            guard isPlausibleConfigs(decoded) else { continue }

            sensorConfigs = decoded
            saveConfigs()
            if debugMigrationLogs { print("✅ Auto-detected key:", key, decoded.count) }
            return
        }

        sensorConfigs = []
        if debugMigrationLogs { print("⚠️ No configs found") }
    }

    private func decodeConfigs(forKey key: String) -> [SensorConfig]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([SensorConfig].self, from: data)
    }

    private func isPlausibleConfigs(_ arr: [SensorConfig]) -> Bool {
        guard !arr.isEmpty else { return false }
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

            let now = Date()
            var rt = self.runtime[id] ?? SensorRuntime()

            // Always update live values
            rt.hr = hr
            rt.rrMs = rrMs
            rt.lastHRAt = now
            rt.isStale = false
            rt.percentOfMax = percent

            // Rate-limit graph samples to 1Hz
            let lastSample = self.historyLastSampleAt[id]
            let canAppend = (lastSample == nil) || (now.timeIntervalSince(lastSample!) >= self.historySamplePeriod)

            if canAppend {
                self.historyLastSampleAt[id] = now
                rt.percentHistory.append(percent)

                // Keep up to 2 hours @ 1Hz
                if rt.percentHistory.count > self.historyMaxSamples {
                    rt.percentHistory.removeFirst(rt.percentHistory.count - self.historyMaxSamples)
                }
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
            bootstrapKnownPeripheralsAndConnectAuto()
        } else {
            stopScan()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        // Broad scan kan hitta "allt" → filtrera bort icke-connectable om flaggan finns
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool, connectable == false {
            return
        }

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
            let rt = runtime[id] ?? SensorRuntime()

            // Prioritera om den är disconnected eller stale (typ “kom upp ur vatten”)
            let needsPriority = (rt.state == .disconnected) || rt.isStale || (rt.lastHRAt == nil)

            if needsPriority {
                connectPeripheralIfEligible(peripheral, id: id, now: now, reason: "discovered priority reconnect")
            } else {
                connectPeripheralIfEligible(peripheral, id: id, now: now, reason: "discovered wanted")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetReconnectPolicy(id: peripheral.identifier)
        setState(id: peripheral.identifier, state: .connected, text: "Ansluten")

        peripheral.delegate = self
        peripheral.discoverServices([hrService, batteryService])

        // OK att läsa RSSI direkt vid connect
        lastRSSIReadAt[peripheral.identifier] = Date()
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
            // ✅ inte readRSSI här
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
