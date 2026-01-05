// SensorsView.swift
// Version 1.0.24
// NOTE (Scanning strategy):
// - För att slippa build-fel när BLECoordinator ändrar startScan-signatur/access,
//   använder vi ENBART ble.userStartScanning() / ble.userStopScanning() från UI.
// - “Upptäckta” bygger på ble.discovered som uppdateras av didDiscover i BLECoordinator.
// - “Mina sensorer” är ble.sensorConfigs (persistade) och kan editas/sparas här.

import SwiftUI

struct SensorsView: View {
    @EnvironmentObject private var ble: BLECoordinator

    @State private var editing: SensorConfig? = nil

    var body: some View {
        List {
            Section {
                HStack {
                    Label(ble.bluetoothText, systemImage: ble.isPoweredOn ? "bolt.heart" : "bolt.slash")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if ble.isScanning {
                        Text("Skannar…").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Mina sensorer") {
                if ble.sensorConfigs.isEmpty {
                    Text("Inga sparade sensorer ännu.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ble.sensorConfigs) { cfg in
                        let rt = ble.runtime[cfg.id] ?? SensorRuntime()
                        SensorRow(cfg: cfg, rt: rt,
                                  onConnect: { ble.connect(id: cfg.id) },
                                  onDisconnect: { ble.disconnect(id: cfg.id) },
                                  onEdit: { editing = cfg })
                    }
                    .onDelete { idx in
                        for i in idx {
                            let id = ble.sensorConfigs[i].id
                            ble.removeSensor(id: id)
                        }
                    }
                }
            }

            Section("Upptäckta (HR via BLE)") {
                if ble.discovered.isEmpty {
                    Text("Tryck Scan för att leta efter pulssensorer.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ble.discovered) { d in
                        DiscoveredRow(d: d,
                                      isAlreadySaved: ble.sensorConfigs.contains(where: { $0.id == d.id }),
                                      onAdd: { ble.addDiscovered(id: d.id, name: d.name) })
                    }
                }
            }
        }
        .navigationTitle("Sensorer")
        .toolbar { toolbarContent }
        .sheet(item: $editing) { cfg in
            EditSensorSheet(cfg: cfg) { updated in
                ble.upsertSensor(updated)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if ble.isScanning {
                Button { ble.userStopScanning() } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
            } else {
                Button { ble.userStartScanning() } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
            }
        }
    }
}

private struct SensorRow: View {
    let cfg: SensorConfig
    let rt: SensorRuntime
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(cfg.avatar).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.displayName).font(.headline).lineLimit(1)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { onEdit() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 12) {
                Text("Max \(cfg.maxHR)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let hr = rt.hr {
                    Text("\(hr) bpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let pct = rt.percentOfMax {
                    let z = HRZone.from(percent: pct)
                    Text("\(z.shortLabel) \(pct)%")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(z.color.opacity(0.18), in: Capsule())
                }

                Spacer()

                if rt.state == .connected || rt.state == .connecting {
                    Button("Disconnect") { onDisconnect() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Connect") { onConnect() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String {
        switch rt.state {
        case .connected: return rt.isStale ? "Ansluten • signal tappad" : "Ansluten • OK"
        case .connecting: return "Ansluter…"
        case .scanning: return "Skannar…"
        case .disconnected: return "Frånkopplad"
        }
    }
}

private struct DiscoveredRow: View {
    let d: DiscoveredSensor
    let isAlreadySaved: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name).font(.headline).lineLimit(1)
                Text(d.rssi.map { "\($0) dBm" } ?? "RSSI —")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isAlreadySaved {
                Text("Sparad")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Button("Lägg till") { onAdd() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct EditSensorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: SensorConfig
    let onSave: (SensorConfig) -> Void

    init(cfg: SensorConfig, onSave: @escaping (SensorConfig) -> Void) {
        _cfg = State(initialValue: cfg)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profil") {
                    TextField("Namn", text: $cfg.displayName)
                    TextField("Avatar", text: $cfg.avatar)
                    Stepper("Maxpuls: \(cfg.maxHR)", value: $cfg.maxHR, in: 60...240)
                }

                Section("Beteende") {
                    Toggle("Auto-connect", isOn: $cfg.autoConnect)
                    Toggle("Visa i Dashboard", isOn: $cfg.showOnDashboard)
                }
            }
            .navigationTitle("Redigera sensor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Spara") {
                        onSave(cfg)
                        dismiss()
                    }
                    .font(.headline)
                }
            }
        }
    }
}
