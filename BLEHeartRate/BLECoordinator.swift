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

    // Runtime per sensor (UI-kort läser härifrån)
    @Published private(set) var runtime: [UUID: SensorRuntime] = [:]

    // Upptäckta enheter under scan (för Add-flow)
    @Published var discovered: [UUID: (name: String, rssi: Int)] = [:]

    // MARK: CoreBluetooth
    private var central: CBCentralManager!

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var hrChar: [UUID: CBCharacteristic] = [:]
    private var batteryChar: [UUID: CBCharacteristic] = [:]

    // reconnect/backoff
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]

    // anti-thrash
    private var lastConnectAttemptAt: [UUID: Date] = [:]
    private let minConnectAttemptInterval: TimeInterval = 1.0
    private let reconnectDelayCapSeconds: Int = 5

    // timers
    private var tickTask: Task<Void, Never>?
    private var rssiTask: Task<Void, Never>?

    // "stale" (tyst HR-data) – UI only, INGEN reconnect
    private let staleAfterSeconds: Int = 10

    // percent history length (t.ex. ~3 minuter vid ~1Hz)
    private let maxHistoryCount: Int = 180

    override init() {
        super.init()

        sensorConfigs = Persistence.loadSensors()
        // Central på main-queue (enklare & stabilt för @Published/UI)
        central = CBCentralManager(delegate: self, queue: nil)

        // init runtime entries
        for cfg in sensorConfigs {
            ensureRuntimeExists(for: cfg.id)
        }

        startTicking()
        startRSSIPolling()
    }

    deinit {
        tickTask?.cancel()
        rssiTask?.cancel()
        for (_, task) in reconnectTasks { task.cancel() }
    }

    // MARK: Public actions

    func startScan() {
        guard isPoweredOn else { return }

        discovered.removeAll()
        isScanning = true

        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func addOrUpdateConfigFromDiscovery(id: UUID, name: String) {
        if let idx = sensorConfigs.firstIndex(where: { $0.id == id }) {
            // uppdatera namn bara om det är default/okänt
            if sensorConfigs[idx].displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || sensorConfigs[idx].displayName == "Sensor" {
                sensorConfigs[idx].displayName = name
            }
        } else {
            sensorConfigs.append(.default(id: id, name: name))
        }
        ensureRuntimeExists(for: id)
    }

    func removeSensor(id: UUID) {
        sensorConfigs.removeAll { $0.id == id }
        runtime[id] = nil

        cancelReconnect(id: id)

        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }

        peripherals[id] = nil
        hrChar[id] = nil
        batteryChar[id] = nil

        ensureScanningForAutoReconnect()
    }

    func updateConfig(_ cfg: SensorConfig) {
        if let idx = sensorConfigs.firstIndex(where: { $0.id == cfg.id }) {
            sensorConfigs[idx] = cfg
        } else {
            sensorConfigs.append(cfg)
        }

        ensureRuntimeExists(for: cfg.id)
        ensureScanningForAutoReconnect()

        if cfg.autoConnect {
            connect(id: cfg.id)
        }
    }

    func connect(id: UUID) {
        ensureRuntimeExists(for: id)

        // anti-thrash: inte oftare än 1 gång/sek per enhet
        let now = Date()
        if let last = lastConnectAttemptAt[id], now.timeIntervalSince(last) < minConnectAttemptInterval {
            return
        }
        lastConnectAttemptAt[id] = now

        // om vi redan försöker ansluta – gör inget
        if runtime[id]?.state == .connecting { return }
        if runtime[id]?.state == .connected { return }

        // försök hitta peripheral: cache -> retrieve -> scan
        let p = peripherals[id] ?? retrieveKnownPeripheral(id: id)

        guard let peripheral = p else {
            setRuntime(id: id) { r in
                r.state = .connecting
                r.statusText = "Väntar på upptäckt…"
            }
            // se till att vi scannar så vi kan hitta den direkt när den kommer upp ur vattnet
            ensureScanningForAutoReconnect()
            scheduleReconnect(id: id, immediate: true)
            return
        }

        setRuntime(id: id) { r in
            r.state = .connecting
            r.statusText = "Ansluter…"
        }

        central.connect(peripheral, options: nil)
    }

    func disconnect(id: UUID) {
        cancelReconnect(id: id)

        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }

        setRuntime(id: id) { r in
            r.state = .disconnected
            r.statusText = "Frånkopplad"
        }

        ensureScanningForAutoReconnect()
    }

    func reconnectAllAuto() {
        for cfg in sensorConfigs where cfg.autoConnect {
            connect(id: cfg.id)
        }
        ensureScanningForAutoReconnect()
    }

    // MARK: Internal helpers

    private func ensureRuntimeExists(for id: UUID) {
        if runtime[id] == nil {
            runtime[id] = SensorRuntime()
        }
    }

    private func setRuntime(id: UUID, mutate: (inout SensorRuntime) -> Void) {
        var r = runtime[id] ?? SensorRuntime()
        mutate(&r)

        // compute percent-of-max
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
        if let found {
            peripherals[id] = found
        }
        return found
    }

    private func cancelReconnect(id: UUID) {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        reconnectAttempts[id] = 0
    }

    private func scheduleReconnect(id: UUID, immediate: Bool = false) {
        guard let cfg = sensorConfigs.first(where: { $0.id == id }), cfg.autoConnect else { return }

        reconnectTasks[id]?.cancel()

        let attempt = (reconnectAttempts[id] ?? 0) + 1
        reconnectAttempts[id] = attempt

        // Backoff: 0,1,2,4,5,5... (cap 5s)
        let seconds: Int
        if immediate {
            seconds = 0
        } else {
            seconds = min(Int(pow(2.0, Double(attempt - 1))), reconnectDelayCapSeconds)
        }

        reconnectTasks[id] = Task { [weak self] in
            guard let self else { return }
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            if Task.isCancelled { return }

            // redan connected? stoppa
            if self.runtime[id]?.state == .connected { return }

            // Viktigt: scanna så fort vi behöver återfå enheten
            self.ensureScanningForAutoReconnect()

            // försök anslut
            self.connect(id: id)

            // om vi inte är connected än, fortsätt försöka (max delay 5s)
            if self.runtime[id]?.state != .connected {
                self.scheduleReconnect(id: id, immediate: false)
            }
        }
    }

    private func ensureScanningForAutoReconnect() {
        guard isPoweredOn else { return }

        let needsScan = sensorConfigs.contains { cfg in
            guard cfg.autoConnect else { return false }
            let st = runtime[cfg.id]?.state ?? .disconnected
            return st != .connected
        }

        if needsScan && !isScanning {
            startScan()
        } else if !needsScan && isScanning {
            // stoppa scanning när allt är tillbaka (spar batteri)
            stopScan()
        }
    }

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

                    // OBS: stale är UI-only – INGEN reconnect
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
                for cfg in self.sensorConfigs {
                    let id = cfg.id
                    if self.runtime[id]?.state == .connected, let p = self.peripherals[id] {
                        p.readRSSI()
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000) // var 3s
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
            // autoconnect direkt
            reconnectAllAuto()

        case .poweredOff:
            bluetoothText = "Bluetooth: Av"
            isPoweredOn = false
            isScanning = false
            stopScan()

            // markera allt som disconnected
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

        // Om vi känner igen en autoConnect-sensor: anslut så fort den dyker upp
        if let cfg = sensorConfigs.first(where: { $0.id == id }), cfg.autoConnect {
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

        // Om alla auto-sensorer är tillbaka kan vi stoppa scanning
        ensureScanningForAutoReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let id = peripheral.identifier

        setRuntime(id: id) { r in
            r.state = .disconnected
            r.statusText = "Kunde inte ansluta"
        }

        ensureScanningForAutoReconnect()
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
            r.statusText = "Frånkopplad (återansluter…)"
            // behåll senaste HR/percentHistory så kortet inte “dör visuellt”
        }

        // pool-case: disconnect är normalt → scanna direkt och försök återanslut snabbt
        ensureScanningForAutoReconnect()
        scheduleReconnect(id: id, immediate: true)
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
                // läs en gång (och du kan läsa igen t.ex. var 5:e minut om du vill)
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
                // uppdatera percentHistory (för sparkline)
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
