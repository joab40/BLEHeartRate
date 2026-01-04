//
//  BLEHeartRateManager.swift
//  BLEHeartRate
//
//  Created by johan on 2026-01-03.
//

import Foundation
import CoreBluetooth
import Combine

// Standard UUIDs för Heart Rate
private let hrServiceUUID = CBUUID(string: "180D")
private let hrMeasurementUUID = CBUUID(string: "2A37")

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class BLEHeartRateManager: NSObject, ObservableObject {

    // UI-state
    @Published var bluetoothStateText: String = "Initierar Bluetooth…"
    @Published var isScanning: Bool = false
    @Published var devices: [DiscoveredDevice] = []

    @Published var connectedName: String = "Ingen"
    @Published var heartRateBpm: Int? = nil
    @Published var statusText: String = "Redo"

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var hrMeasurementChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            statusText = "Bluetooth är inte på."
            return
        }
        devices.removeAll()
        heartRateBpm = nil
        statusText = "Skannar…"
        isScanning = true

        // För “enklast möjligt”: scanna allt.
        // När det funkar kan du filtrera på [hrServiceUUID] för stabilare listor.
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        statusText = "Scan stoppad"
    }

    func connect(to device: DiscoveredDevice) {
        stopScan()
        statusText = "Ansluter till \(device.name)…"
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        guard let p = connectedPeripheral else { return }
        statusText = "Kopplar från…"
        central.cancelPeripheralConnection(p)
    }

    private func resetConnectionState() {
        connectedPeripheral = nil
        hrMeasurementChar = nil
        connectedName = "Ingen"
        heartRateBpm = nil
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEHeartRateManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStateText = "Bluetooth: På"
            statusText = "Redo"
        case .poweredOff:
            bluetoothStateText = "Bluetooth: Av"
            statusText = "Slå på Bluetooth"
            stopScan()
            resetConnectionState()
        case .unauthorized:
            bluetoothStateText = "Bluetooth: Ingen behörighet"
            statusText = "Ge Bluetooth-behörighet i Inställningar"
        case .unsupported:
            bluetoothStateText = "Bluetooth: Stöds ej"
            statusText = "Enheten stöder inte BLE"
        case .resetting:
            bluetoothStateText = "Bluetooth: Återställs…"
            statusText = "Vänta…"
        case .unknown:
            bluetoothStateText = "Bluetooth: Okänd status"
            statusText = "Vänta…"
        @unknown default:
            bluetoothStateText = "Bluetooth: Okänd status"
            statusText = "Vänta…"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {

        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Okänd enhet"
        let rssi = RSSI.intValue

        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = rssi
            if devices[idx].name == "Okänd enhet", name != "Okänd enhet" {
                devices[idx].name = name
            }
        } else {
            devices.append(DiscoveredDevice(
                id: peripheral.identifier,
                peripheral: peripheral,
                name: name,
                rssi: rssi
            ))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        connectedName = peripheral.name ?? "Ansluten enhet"
        statusText = "Ansluten. Söker Heart Rate service…"

        peripheral.delegate = self
        // Vi letar specifikt efter 180D för att få puls om den finns.
        peripheral.discoverServices([hrServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        statusText = "Kunde inte ansluta: \(error?.localizedDescription ?? "okänt fel")"
        resetConnectionState()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let error {
            statusText = "Frånkopplad: \(error.localizedDescription)"
        } else {
            statusText = "Frånkopplad"
        }
        resetConnectionState()
    }
}

// MARK: - CBPeripheralDelegate
extension BLEHeartRateManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusText = "Service-fel: \(error.localizedDescription)"
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            statusText = "Ingen Heart Rate service (180D) hittades på enheten."
            return
        }

        for service in services where service.uuid == hrServiceUUID {
            statusText = "Hittade 180D. Letar 2A37…"
            peripheral.discoverCharacteristics([hrMeasurementUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            statusText = "Characteristic-fel: \(error.localizedDescription)"
            return
        }

        guard let chars = service.characteristics else {
            statusText = "Inga characteristics hittades."
            return
        }

        if let hrChar = chars.first(where: { $0.uuid == hrMeasurementUUID }) {
            hrMeasurementChar = hrChar
            statusText = "Prenumererar på puls (notify)…"
            peripheral.setNotifyValue(true, for: hrChar)
        } else {
            statusText = "2A37 saknas – enheten exponerar inte standard puls."
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            statusText = "Notify-fel: \(error.localizedDescription)"
            return
        }
        if characteristic.uuid == hrMeasurementUUID, characteristic.isNotifying {
            statusText = "Tar emot pulsdata…"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            statusText = "Läsfel: \(error.localizedDescription)"
            return
        }
        guard characteristic.uuid == hrMeasurementUUID,
              let data = characteristic.value else { return }

        if let bpm = parseHeartRate(from: data) {
            heartRateBpm = bpm
        }
    }

    private func parseHeartRate(from data: Data) -> Int? {
        // Heart Rate Measurement format:
        // Byte0 = flags. Bit0: 0 = uint8 HR, 1 = uint16 HR
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }

        let flags = bytes[0]
        let isUInt16 = (flags & 0x01) != 0

        if !isUInt16 {
            return Int(bytes[1])
        } else {
            guard bytes.count >= 3 else { return nil }
            let value = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return Int(value)
        }
    }
}
