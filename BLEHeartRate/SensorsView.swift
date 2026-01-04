// Version 1.0.11
import SwiftUI

struct SensorsView: View {
    @EnvironmentObject private var ble: BLECoordinator

    @State private var scanEnabled: Bool = false
    @State private var editingSensor: SensorConfig? = nil

    var body: some View {
        NavigationStack {
            List {
                // Scan-toggle
                Section {
                    HStack {
                        Toggle(isOn: $scanEnabled) {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                Text("Skanna")
                            }
                        }
                        .toggleStyle(.switch)

                        Spacer()

                        if ble.isScanning {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Text(ble.isScanning ? "Scanning är på — sensorer dyker upp under ‘Upptäckta’." :
                                         "Slå på scanning för att hitta sensorer i närheten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Mina sensorer
                Section("Mina sensorer") {
                    if ble.sensorConfigs.isEmpty {
                        Text("Inga sensorer ännu. Slå på Skanna och lägg till.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ble.sensorConfigs) { cfg in
                            Button {
                                editingSensor = cfg
                            } label: {
                                SensorRow(cfg: cfg)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    ble.removeSensor(id: cfg.id)
                                } label: {
                                    Label("Ta bort", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    var updated = cfg
                                    updated.showOnDashboard.toggle()
                                    ble.updateConfig(updated)
                                } label: {
                                    Label(cfg.showOnDashboard ? "Dölj" : "Visa",
                                          systemImage: cfg.showOnDashboard ? "eye.slash" : "eye")
                                }
                                .tint(cfg.showOnDashboard ? .gray : .green)
                            }
                        }
                        .onDelete(perform: deleteRows)
                    }
                }

                // Upptäckta
                Section("Upptäckta") {
                    if ble.discovered.isEmpty {
                        Text(ble.isScanning ? "Letar…" : "Scanning är av.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ble.discovered.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                            if let d = ble.discovered[id] {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.name)
                                            .font(.headline)
                                        Text(id.uuidString)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text("\(d.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Button("Lägg till") {
                                        ble.addOrUpdateConfigFromDiscovery(id: id, name: d.name)

                                        // Öppna edit direkt så man kan sätta namn/avatar/maxHR + showOnDashboard
                                        if let added = ble.sensorConfigs.first(where: { $0.id == id }) {
                                            editingSensor = added
                                        }

                                        ble.connect(id: id)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sensorer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .onAppear {
                scanEnabled = ble.isScanning
            }
            .onChange(of: ble.isScanning) { _, newValue in
                if scanEnabled != newValue { scanEnabled = newValue }
            }
            .onChange(of: scanEnabled) { _, enabled in
                enabled ? ble.startScan() : ble.stopScan()
            }
            .sheet(item: $editingSensor) { cfg in
                EditSensorView(config: cfg) { updated in
                    ble.updateConfig(updated)
                } onDelete: { id in
                    ble.removeSensor(id: id)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func deleteRows(at offsets: IndexSet) {
        let ids = offsets.map { ble.sensorConfigs[$0].id }
        for id in ids { ble.removeSensor(id: id) }
    }
}

// MARK: - Row

private struct SensorRow: View {
    @EnvironmentObject private var ble: BLECoordinator
    let cfg: SensorConfig

    private var rt: SensorRuntime { ble.runtime[cfg.id] ?? SensorRuntime() }

    var body: some View {
        HStack(spacing: 12) {
            Text(cfg.avatar)
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(cfg.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if !cfg.showOnDashboard {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let hr = rt.hr {
                    Text("\(hr) bpm")
                        .font(.subheadline.weight(.semibold))
                }

                Text("Max \(cfg.maxHR)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
        .padding(.vertical, 6)
    }

    private var statusLine: String {
        switch rt.state {
        case ConnectionState.connected:
            return rt.isStale ? "Ansluten • Signal tappad" : "Ansluten"
        case ConnectionState.connecting:
            return "Ansluter…"
        case ConnectionState.scanning:
            return "Skannar…"
        case ConnectionState.disconnected:
            return "Frånkopplad"
        }
    }
}
