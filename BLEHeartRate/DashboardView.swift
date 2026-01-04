import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var ble: BLECoordinator

    var body: some View {
        GeometryReader { geo in
            // ✅ Viktigt: gör lokala kopior med explicit typ
            let configs: [SensorConfig] = ble.sensorConfigs
            let runtimes: [UUID: SensorRuntime] = ble.runtime

            let count = configs.count
            let columns = gridColumns(for: count)
            let cardHeight = cardMinHeight(container: geo.size, count: count)

            ScrollView {
                VStack(spacing: 12) {
                    header

                    if count == 0 {
                        ContentUnavailableView(
                            "Inga sensorer",
                            systemImage: "dot.radiowaves.left.and.right",
                            description: Text("Gå till Sensorer och lägg till en pulssensor.")
                        )
                        .padding(.horizontal)
                        .padding(.top, 12)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(configs) { cfg in
                                // ✅ Hämtas från lokala runtimes (inte ble.runtime direkt)
                                let rt = runtimes[cfg.id] ?? SensorRuntime()

                                SensorCard(cfg: cfg, rt: rt)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: cardHeight)
                                    .contextMenu {
                                        Button("Reconnect") { ble.connect(id: cfg.id) }
                                        Button("Disconnect") { ble.disconnect(id: cfg.id) }
                                        Divider()
                                        Button(role: .destructive) { ble.removeSensor(id: cfg.id) } label: {
                                            Text("Ta bort")
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
                .frame(minHeight: geo.size.height)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("HR Monitor")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { ble.reconnectAllAuto() } label: {
                        Label("Reconnect all", systemImage: "arrow.clockwise")
                    }

                    if ble.isScanning {
                        Button { ble.stopScan() } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    } else {
                        Button { ble.startScan() } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(ble.bluetoothText, systemImage: ble.isPoweredOn ? "bolt.heart" : "bolt.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if ble.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Skannar…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            if !ble.sensorConfigs.isEmpty {
                Text("Tryck och håll på ett kort för snabbmeny.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Grid sizing

    private func gridColumns(for count: Int) -> [GridItem] {
        let cols: Int
        switch count {
        case 0, 1: cols = 1
        case 2: cols = 2
        case 3, 4: cols = 2
        case 5, 6: cols = 3
        case 7, 8, 9: cols = 3
        default: cols = Int(ceil(sqrt(Double(count))))
        }
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: cols)
    }

    private func cardMinHeight(container: CGSize, count: Int) -> CGFloat {
        let h = container.height
        switch count {
        case 0: return 0
        case 1: return max(280, h * 0.72)
        case 2: return max(240, h * 0.55)
        case 3, 4: return max(220, h * 0.36)
        case 5, 6: return max(200, h * 0.28)
        default: return 190
        }
    }
}

// MARK: - Card

private struct SensorCard: View {
    let cfg: SensorConfig
    let rt: SensorRuntime

    var body: some View {
        let bpmText = rt.hr.map(String.init) ?? "—"
        let pctText = rt.percentOfMax.map { "\($0)%" } ?? "—%"
        let zone = rt.percentOfMax.map { HRZone.from(percent: $0) }

        VStack(alignment: .leading, spacing: 12) {

            HStack(alignment: .top) {
                Text(cfg.avatar).font(.system(size: 34))

                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let b = rt.battery {
                        Label("\(b)%", systemImage: "battery.100")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let rssi = rt.rssi {
                        Text("\(rssi) dBm")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(bpmText)
                    .font(.system(size: 52, weight: .bold, design: .rounded))

                Text("bpm")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(pctText).font(.headline)
                    Text("av max \(cfg.maxHR)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SparklineView(values: rt.percentHistory)
                .opacity(rt.percentHistory.isEmpty ? 0.55 : 1.0)

            HStack {
                if let rr = rt.rrMs {
                    Label("\(rr) ms", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("RR —", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("seen \(rt.lastSeenSeconds)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let zone {
                ZoneBar(zone: zone, isStale: rt.isStale)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 10)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .shadow(radius: 8, y: 3)
    }

    private var statusLine: String {
        switch rt.state {
        case ConnectionState.connected:
            return rt.isStale ? "Ansluten • Signal tappad" : "Ansluten • OK"
        case ConnectionState.connecting:
            return "Ansluter…"
        case ConnectionState.scanning:
            return "Skannar…"
        case ConnectionState.disconnected:
            return "Frånkopplad"
        }
    }

    private var borderColor: Color {
        if rt.isStale { return .orange.opacity(0.7) }
        if rt.state == ConnectionState.connected { return .primary.opacity(0.08) }
        return .primary.opacity(0.05)
    }
}

// MARK: - ZoneBar

private struct ZoneBar: View {
    let zone: HRZone
    let isStale: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.opacity(isStale ? 0.35 : 0.9))
            .frame(height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
    }

    private var color: Color {
        switch zone {
        case .z1: return .blue
        case .z2: return .green
        case .z3: return .yellow
        case .z4: return .orange
        case .z5: return .red
        }
    }
}
