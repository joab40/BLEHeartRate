// Tag 1.0.4
import SwiftUI

struct SensorsView: View {
    @EnvironmentObject private var ble: BLECoordinator

    @State private var showingDiscovered = false

    var body: some View {
        NavigationStack {
            List {
                // Mina sensorer
                Section("Mina sensorer") {
                    if ble.sensorConfigs.isEmpty {
                        Text("Inga sensorer ännu. Tryck + för att lägga till.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ble.sensorConfigs) { cfg in
                            SensorRow(cfg: cfg)
                                .environmentObject(ble)
                        }
                        .onDelete(perform: deleteRows) // swipe-to-delete
                    }
                }

                // Upptäckta (valfritt)
                Section("Upptäckta (scan)") {
                    if ble.discovered.isEmpty {
                        Text(ble.isScanning ? "Skannar…" : "Tryck Scan för att hitta sensorer.")
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()

                    if ble.isScanning {
                        Button {
                            ble.stopScan()
                        } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            ble.startScan()
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
        }
    }

    private func deleteRows(at offsets: IndexSet) {
        let ids = offsets.map { ble.sensorConfigs[$0].id }
        for id in ids {
            ble.removeSensor(id: id)
        }
    }
}

// MARK: - Row

private struct SensorRow: View {
    @EnvironmentObject private var ble: BLECoordinator
    let cfg: SensorConfig

    var rt: SensorRuntime { ble.runtime[cfg.id] ?? SensorRuntime() }

    var body: some View {
        HStack(spacing: 12) {
            Text(cfg.avatar)
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 4) {
                Text(cfg.displayName)
                    .font(.headline)
                    .lineLimit(1)

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

                HStack(spacing: 8) {
                    Button {
                        ble.connect(id: cfg.id)
                    } label: {
                        Image(systemName: "link")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        ble.disconnect(id: cfg.id)
                    } label: {
                        Image(systemName: "link.badge.minus")
                    }
                    .buttonStyle(.borderless)

                    Button(role: .destructive) {
                        ble.removeSensor(id: cfg.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                ble.removeSensor(id: cfg.id)
            } label: {
                Label("Ta bort", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if rt.state != ConnectionState.connected {
                Button {
                    ble.connect(id: cfg.id)
                } label: {
                    Label("Anslut", systemImage: "link")
                }
                .tint(.green)
            } else {
                Button {
                    ble.disconnect(id: cfg.id)
                } label: {
                    Label("Koppla från", systemImage: "link.badge.minus")
                }
                .tint(.orange)
            }
        }
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
