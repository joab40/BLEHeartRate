//
//  SensorsView.swift
//  BLEHeartRate
//
//  Created by johan on 2026-01-04.
//

import SwiftUI

struct SensorsView: View {
    @EnvironmentObject var ble: BLECoordinator
    @State private var showScanner = false
    @State private var editConfig: SensorConfig?

    var body: some View {
        List {
            Section {
                Button {
                    showScanner = true
                    if !ble.isScanning { ble.startScan() }
                } label: {
                    Label("Lägg till / Scanna", systemImage: "plus.circle")
                }

                Button {
                    ble.reconnectAllAuto()
                } label: {
                    Label("Reconnect auto-sens.", systemImage: "arrow.clockwise")
                }
            }

            Section("Sparade sensorer") {
                if ble.sensorConfigs.isEmpty {
                    Text("Inga sensorer ännu.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ble.sensorConfigs) { cfg in
                        let rt = ble.runtime[cfg.id] ?? SensorRuntime()

                        HStack {
                            Text(cfg.avatar).font(.title2)
                            VStack(alignment: .leading) {
                                Text(cfg.displayName)
                                Text(rt.state == .connected ? "Ansluten" : (cfg.autoConnect ? "Auto-connect" : "Manuell"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let hr = rt.hr {
                                Text("\(hr)")
                                    .font(.headline)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editConfig = cfg
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { ble.removeSensor(id: cfg.id) } label: {
                                Label("Ta bort", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { ble.connect(id: cfg.id) } label: {
                                Label("Connect", systemImage: "link")
                            }.tint(.blue)

                            Button { ble.disconnect(id: cfg.id) } label: {
                                Label("Disconnect", systemImage: "link.slash")
                            }.tint(.gray)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sensorer")
        .sheet(isPresented: $showScanner) {
            ScannerSheet(isPresented: $showScanner)
                .environmentObject(ble)
        }
        .sheet(item: $editConfig) { cfg in
            EditSensorSheet(cfg: cfg)
                .environmentObject(ble)
        }
    }
}

private struct ScannerSheet: View {
    @EnvironmentObject var ble: BLECoordinator
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(ble.bluetoothText).foregroundStyle(.secondary)
                        Spacer()
                        if ble.isScanning {
                            ProgressView()
                        }
                    }
                }

                Section("Hittade enheter") {
                    if ble.discovered.isEmpty {
                        Text("Inga enheter ännu…")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ble.discovered.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                            let d = ble.discovered[id]!
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(d.name)
                                    Text("\(id.uuidString)")
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
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stäng") {
                        isPresented = false
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if ble.isScanning {
                        Button("Stop") { ble.stopScan() }
                    } else {
                        Button("Scan") { ble.startScan() }
                    }
                }
            }
        }
        .onDisappear {
            // låt scanning fortsätta om du vill – men här stoppar vi för att spara batteri
            ble.stopScan()
        }
    }
}

private struct EditSensorSheet: View {
    @EnvironmentObject var ble: BLECoordinator
    @Environment(\.dismiss) var dismiss

    @State var cfg: SensorConfig

    var body: some View {
        NavigationStack {
            Form {
                Section("Utseende") {
                    TextField("Namn", text: $cfg.displayName)
                    TextField("Avatar (emoji)", text: $cfg.avatar)
                }

                Section("Träning") {
                    Stepper("Maxpuls: \(cfg.maxHR)", value: $cfg.maxHR, in: 60...230)
                    Toggle("Auto-connect", isOn: $cfg.autoConnect)
                }

                Section {
                    Button("Connect") { ble.connect(id: cfg.id) }
                    Button("Disconnect") { ble.disconnect(id: cfg.id) }
                }
            }
            .navigationTitle("Sensor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spara") {
                        ble.updateConfig(cfg)
                        dismiss()
                    }
                }
            }
        }
    }
}
