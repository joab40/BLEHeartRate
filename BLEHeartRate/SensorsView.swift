// SensorsView.swift
// Version 1.0.25
// NOTE (Scanning + Tuning):
// - “Scan” i denna vy kör broad scan (withServices: nil) för att hitta nya enheter som inte alltid annonserar 180D.
// - “Stop” stänger av auto-scan (scanMode = manualOff).
// - Under “BLE tuning” kan du justera globala timeouts/holdoffs (Variant A). De gäller alla sensorer och sparas lokalt.

import SwiftUI

struct SensorsView: View {
    @EnvironmentObject private var ble: BLECoordinator

    var body: some View {
        List {
            statusSection
            scanSection
            tuningSection
            savedSection
            discoveredSection
        }
        .navigationTitle("Sensorer")
        .onAppear {
            // När man öppnar SensorsView vill man ofta se nya enheter direkt
            if ble.scanMode == .auto, !ble.isScanning {
                ble.startBroadScan()
            }
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack {
                Label(ble.bluetoothText, systemImage: ble.isPoweredOn ? "bolt.heart" : "bolt.slash")
                    .foregroundStyle(.secondary)
                Spacer()
                if ble.isPoweredOn {
                    Image(systemName: ble.isScanning ? "dot.radiowaves.left.and.right" : "checkmark.circle")
                        .foregroundStyle(ble.isScanning ? .blue : .green)
                }
            }
        }
    }

    private var scanSection: some View {
        Section("Skanning") {
            if ble.isScanning {
                Button {
                    ble.userStopScanning()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
            } else {
                Button {
                    ble.userStartScanning()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
            }

            if ble.scanMode == .manualOff {
                Text("Auto-scan är avstängt (manuellt). Tryck “Scan” för att slå på igen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tuningSection: some View {
        Section {
            Stepper(value: bindingInt(\.staleSoftSeconds), in: 2...30) {
                LabeledContent("Soft stale (s)") {
                    Text("\(ble.tuning.staleSoftSeconds)")
                }
            }

            Stepper(value: bindingInt(\.staleHardResetSeconds), in: 6...60) {
                LabeledContent("Hard reset (s)") {
                    Text("\(ble.tuning.staleHardResetSeconds)")
                }
            }

            Stepper(value: bindingDouble(\.postHardResetHoldoffSeconds), in: 0.0...5.0, step: 0.1) {
                LabeledContent("Holdoff efter hard reset (s)") {
                    Text(String(format: "%.1f", ble.tuning.postHardResetHoldoffSeconds))
                }
            }

            Stepper(value: bindingDouble(\.minConnectAttemptInterval), in: 0.0...5.0, step: 0.1) {
                LabeledContent("Min connect-intervall (s)") {
                    Text(String(format: "%.1f", ble.tuning.minConnectAttemptInterval))
                }
            }

            Stepper(value: bindingDouble(\.minRSSIInterval), in: 0.2...5.0, step: 0.1) {
                LabeledContent("Min RSSI-intervall (s)") {
                    Text(String(format: "%.1f", ble.tuning.minRSSIInterval))
                }
            }

            Button(role: .destructive) {
                ble.tuning = .default
            } label: {
                Label("Återställ BLE tuning", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("BLE tuning (globalt)")
        } footer: {
            Text("Tips: Om appen reconnect-loopar efter att simmaren varit utom räckhåll, höj “Hard reset (s)” och/eller “Holdoff”. Om du vill se ‘signal tappad’ tidigare i UI, sänk “Soft stale (s)”.")
        }
    }

    private var savedSection: some View {
        Section("Sparade sensorer") {
            if ble.sensorConfigs.isEmpty {
                Text("Inga sparade sensorer ännu.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.sensorConfigs) { cfg in
                    SensorRow(cfg: cfg, rt: ble.runtime[cfg.id] ?? SensorRuntime())
                        .swipeActions(allowsFullSwipe: false) {
                            Button(role: .destructive) { ble.removeSensor(id: cfg.id) } label: {
                                Label("Ta bort", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Connect") { ble.connect(id: cfg.id) }
                            Button("Disconnect") { ble.disconnect(id: cfg.id) }
                        }
                }
            }
        }
    }

    private var discoveredSection: some View {
        Section("Upptäckta enheter") {
            if ble.discovered.isEmpty {
                Text("Inga enheter upptäckta ännu. Tryck “Scan”.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ble.discovered) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(d.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text(d.id.uuidString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if let rssi = d.rssi {
                            Text("\(rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button("Lägg till") {
                            ble.addDiscovered(id: d.id, name: d.name)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - Helpers (Bindings)

    private func bindingInt(_ kp: WritableKeyPath<BLEGlobalTuning, Int>) -> Binding<Int> {
        Binding(
            get: { ble.tuning[keyPath: kp] },
            set: { newValue in
                var t = ble.tuning
                t[keyPath: kp] = newValue
                ble.tuning = t
            }
        )
    }

    private func bindingDouble(_ kp: WritableKeyPath<BLEGlobalTuning, TimeInterval>) -> Binding<Double> {
        Binding(
            get: { ble.tuning[keyPath: kp] },
            set: { newValue in
                var t = ble.tuning
                t[keyPath: kp] = newValue
                ble.tuning = t
            }
        )
    }
}

// MARK: - Row

private struct SensorRow: View {
    let cfg: SensorConfig
    let rt: SensorRuntime

    var body: some View {
        HStack(spacing: 12) {
            Text(cfg.avatar)
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 4) {
                Text(cfg.displayName).font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(rt.hr.map(String.init) ?? "—")
                    .font(.title3.weight(.semibold))

                if let pct = rt.percentOfMax {
                    Text("\(HRZone.from(percent: pct).shortLabel)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var statusText: String {
        switch rt.state {
        case .connected:
            return rt.isStale ? "Ansluten • stale" : "Ansluten"
        case .connecting:
            return "Ansluter…"
        case .scanning:
            return "Skannar…"
        case .disconnected:
            return "Frånkopplad"
        }
    }
}
