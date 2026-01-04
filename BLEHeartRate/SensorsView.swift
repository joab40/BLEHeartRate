// Version 1.0.5
import SwiftUI

struct SensorsView: View {
    @EnvironmentObject private var ble: BLECoordinator

    // Lokal UI-state som speglar ble.isScanning
    @State private var scanEnabled: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // ✅ Tydlig scan-toggle överst
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

                Section("Mina sensorer") {
                    if ble.sensorConfigs.isEmpty {
                        Text("Inga sensorer ännu. Slå på Skanna och lägg till.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ble.sensorConfigs) { cfg in
                            SensorRow(cfg: cfg)
                                .environmentObject(ble)
                        }
                        .onDelete(perform: deleteRows)
                    }
                }

                Section("Upptäckta") {
                    if ble.discovered.isEmpty {
                        Text(ble.isScanning ? "Letar…" : "Scanning är av.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ble.discovered.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                            if let d = ble.discovered[id] {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.name).font(.headline)
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
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .onAppear {
                // synka toggle med verkligt scanningläge
                scanEnabled = ble.isScanning
            }
            .onChange(of: ble.isScanning) { _, newValue in
                // håll toggle i sync om scanning ändras av annan vy (Dashboard)
                if scanEnabled != newValue {
                    scanEnabled = newValue
                }
            }
            .onChange(of: scanEnabled) { _, enabled in
                // Toggle styr scanning
                if enabled {
                    ble.startScan()
                } else {
                    ble.stopScan()
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

                HStack(spacing: 10) {
                    Button { ble.connect(id: cfg.id) } label: { Image(systemName: "link") }
                        .buttonStyle(.borderless)

                    Button { ble.disconnect(id: cfg.id) } label: { Image(systemName: "link.badge.minus") }
                        .buttonStyle(.borderless)

                    Button(role: .destructive) { ble.removeSensor(id: cfg.id) } label: { Image(systemName: "trash") }
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
