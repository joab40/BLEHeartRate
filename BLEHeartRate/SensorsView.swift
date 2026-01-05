// Version 1.0.15
import SwiftUI

struct SensorsView: View {
    @EnvironmentObject private var ble: BLECoordinator
    @State private var editing: SensorConfig? = nil

    var body: some View {
        NavigationStack {
            List {
                savedSection
                discoveredSection
            }
            .navigationTitle("Sensorer")
            .toolbar { toolbarContent }
            .sheet(item: $editing) { cfg in
                EditSensorView(
                    config: cfg,
                    onSave: { updated in
                        ble.upsertSensor(updated)
                    },
                    onDelete: { _ in
                        ble.removeSensor(id: cfg.id)
                    }
                )
            }
        }
    }

    private var savedSection: some View {
        Section(header: Text("Mina sensorer")) {
            if ble.sensorConfigs.isEmpty {
                Text("Inga sensorer sparade ännu.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.sensorConfigs) { cfg in
                    let rt = ble.runtime[cfg.id]
                    SensorConfigRow(
                        cfg: cfg,
                        rt: rt,
                        onToggleDashboard: { newVal in
                            var updated = cfg
                            updated.showOnDashboard = newVal
                            ble.upsertSensor(updated)
                        },
                        onToggleAutoConnect: { newVal in
                            var updated = cfg
                            updated.autoConnect = newVal
                            ble.upsertSensor(updated)
                        },
                        onEdit: { editing = cfg },
                        onRemove: { ble.removeSensor(id: cfg.id) },
                        onConnect: { ble.connect(id: cfg.id) },
                        onDisconnect: { ble.disconnect(id: cfg.id) }
                    )
                }
                .onDelete(perform: deleteSaved)
            }
        }
    }

    private var discoveredSection: some View {
        Section(header: Text("Upptäckta")) {

            ScanControlRow(
                isPoweredOn: ble.isPoweredOn,
                isScanning: ble.isScanning,
                onStart: { ble.userStartScanning() },
                onStop: { ble.userStopScanning() }
            )

            if !ble.isPoweredOn {
                Text("Bluetooth är avstängt eller ej tillåtet.")
                    .foregroundStyle(.secondary)
            } else if ble.discovered.isEmpty {
                Text(ble.isScanning ? "Skannar…" : "Tryck Scan för att hitta sensorer.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.discovered) { d in
                    DiscoveredRow(
                        d: d,
                        isSaved: ble.sensorConfigs.contains(where: { $0.id == d.id }),
                        onAdd: { ble.addDiscovered(id: d.id, name: d.name) },
                        onConnect: { ble.connect(id: d.id) }
                    )
                }
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

            Button { ble.reconnectAllAuto() } label: {
                Label("Auto", systemImage: "arrow.clockwise")
            }
        }
    }

    private func deleteSaved(at offsets: IndexSet) {
        let idsToDelete: [UUID] = offsets.map { ble.sensorConfigs[$0].id }
        for id in idsToDelete {
            ble.removeSensor(id: id)
        }
    }
}

// MARK: - Scan control row

private struct ScanControlRow: View {
    let isPoweredOn: Bool
    let isScanning: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isScanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(isPoweredOn ? .primary : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(isScanning ? "Skannar…" : "Skanning")
                    .font(.headline)
                Text(isPoweredOn ? (isScanning ? "Tryck Stop för att avsluta skanning." : "Tryck Scan för att börja.") : "Bluetooth är avstängt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isPoweredOn {
                Text("Av")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if isScanning {
                Button { onStop() } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
            } else {
                Button { onStart() } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Saved sensor row

private struct SensorConfigRow: View {
    let cfg: SensorConfig
    let rt: SensorRuntime?

    let onToggleDashboard: (Bool) -> Void
    let onToggleAutoConnect: (Bool) -> Void

    let onEdit: () -> Void
    let onRemove: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topLine
            toggles
            actions
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onRemove() } label: {
                Label("Ta bort", systemImage: "trash")
            }
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }

    private var topLine: some View {
        HStack(spacing: 12) {
            Text(cfg.avatar)
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 2) {
                Text(cfg.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(hrText).font(.headline)
                Text(rssiText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toggles: some View {
        VStack(spacing: 6) {
            Toggle(
                isOn: Binding(
                    get: { cfg.showOnDashboard },
                    set: { onToggleDashboard($0) }
                )
            ) {
                Label("Visa i Dashboard", systemImage: cfg.showOnDashboard ? "eye" : "eye.slash")
            }

            Toggle(
                isOn: Binding(
                    get: { cfg.autoConnect },
                    set: { onToggleAutoConnect($0) }
                )
            ) {
                Label("Auto-connect", systemImage: "bolt.horizontal.circle")
            }
        }
        .font(.subheadline)
    }

    private var actions: some View {
        HStack {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }

            Spacer()

            if rt?.state == .connected {
                Button { onDisconnect() } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } else {
                Button { onConnect() } label: {
                    Label("Connect", systemImage: "link")
                }
            }
        }
        .font(.subheadline)
    }

    private var statusText: String {
        guard let rt else { return "Ej ansluten" }
        switch rt.state {
        case .connected:
            return rt.isStale ? "Ansluten • signal tappad" : "Ansluten"
        case .connecting:
            return "Ansluter…"
        case .scanning:
            return "Hittad • redo"
        case .disconnected:
            return "Frånkopplad"
        }
    }

    private var hrText: String {
        if let hr = rt?.hr { return "\(hr) bpm" }
        return "— bpm"
    }

    private var rssiText: String {
        if let rssi = rt?.rssi { return "\(rssi) dBm" }
        return ""
    }
}

// MARK: - Discovered row

private struct DiscoveredRow: View {
    let d: DiscoveredSensor
    let isSaved: Bool
    let onAdd: () -> Void
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(d.name)
                    .font(.body)
                    .lineLimit(1)

                Text(d.rssi.map { "\($0) dBm" } ?? "— dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSaved {
                Button("Connect") { onConnect() }
                    .buttonStyle(.bordered)
            } else {
                Button("Lägg till") { onAdd() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
