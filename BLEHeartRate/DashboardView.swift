// Version 1.0.11
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var ble: BLECoordinator

    var body: some View {
        GeometryReader { geo in
            // ✅ Filtrera bort dolda sensorer
            let visibleConfigs: [SensorConfig] = ble.sensorConfigs.filter { $0.showOnDashboard }
            let runtimes: [UUID: SensorRuntime] = ble.runtime
            let visibleCount = visibleConfigs.count
            let totalCount = ble.sensorConfigs.count

            let isWide = geo.size.width >= 700 || geo.size.width > geo.size.height

            VStack(spacing: 12) {
                header

                if totalCount > 0 && visibleCount == 0 {
                    ContentUnavailableView(
                        "Dashboard är tom",
                        systemImage: "eye.slash",
                        description: Text("Alla sensorer är dolda. Gå till Sensorer och slå på “Visa i Dashboard”.")
                    )
                    .padding(.horizontal)
                    Spacer(minLength: 0)

                } else if visibleCount == 0 {
                    ContentUnavailableView(
                        "Inga sensorer",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Gå till Sensorer och lägg till en pulssensor.")
                    )
                    .padding(.horizontal)
                    Spacer(minLength: 0)

                } else if visibleCount <= 4 {
                    fillLayout(configs: visibleConfigs, runtimes: runtimes, isWide: isWide)
                        .frame(maxHeight: .infinity)

                } else {
                    ScrollView {
                        let cols = gridColsForMany(width: geo.size.width)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols),
                            spacing: 14
                        ) {
                            ForEach(visibleConfigs) { cfg in
                                let rt = runtimes[cfg.id] ?? SensorRuntime()
                                SensorCard(cfg: cfg, rt: rt, compact: true)
                                    .frame(minHeight: 190)
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
            }
            .padding(.top, 8)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("HR Monitor")
            .toolbar { toolbarContent }
            // ✅ minimera “flicker” vid många uppdateringar
            .transaction { tx in tx.animation = nil }
        }
    }

    // MARK: Header + Toolbar

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
                Text("Korten fyller skärmen när få sensorer finns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    // MARK: Fill-layout (1–4)

    @ViewBuilder
    private func fillLayout(configs: [SensorConfig],
                            runtimes: [UUID: SensorRuntime],
                            isWide: Bool) -> some View {
        let spacing: CGFloat = 14

        switch configs.count {
        case 1:
            let cfg = configs[0]
            let rt = runtimes[cfg.id] ?? SensorRuntime()
            SensorCard(cfg: cfg, rt: rt, compact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 18)

        case 2:
            let c0 = configs[0]; let r0 = runtimes[c0.id] ?? SensorRuntime()
            let c1 = configs[1]; let r1 = runtimes[c1.id] ?? SensorRuntime()

            Group {
                if isWide {
                    HStack(spacing: spacing) {
                        SensorCard(cfg: c0, rt: r0, compact: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        SensorCard(cfg: c1, rt: r1, compact: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: spacing) {
                        SensorCard(cfg: c0, rt: r0, compact: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        SensorCard(cfg: c1, rt: r1, compact: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 18)

        case 3, 4:
            let top = Array(configs.prefix(2))
            let bottom = Array(configs.dropFirst(2))

            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    ForEach(top) { cfg in
                        let rt = runtimes[cfg.id] ?? SensorRuntime()
                        SensorCard(cfg: cfg, rt: rt, compact: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: spacing) {
                    if bottom.isEmpty {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ForEach(bottom) { cfg in
                            let rt = runtimes[cfg.id] ?? SensorRuntime()
                            SensorCard(cfg: cfg, rt: rt, compact: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if bottom.count == 1 {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal)
            .padding(.bottom, 18)

        default:
            EmptyView()
        }
    }

    private func gridColsForMany(width: CGFloat) -> Int {
        if width >= 900 { return 4 }
        if width >= 700 { return 3 }
        return 2
    }
}

// MARK: - Sensor card

private struct SensorCard: View {
    let cfg: SensorConfig
    let rt: SensorRuntime
    let compact: Bool

    var body: some View {
        let bpmText = rt.hr.map(String.init) ?? "—"
        let pctText = rt.percentOfMax.map { "\($0)%" } ?? "—%"
        let zone = rt.percentOfMax.map { HRZone.from(percent: $0) }

        let hrFont: Font = compact
            ? .system(size: 52, weight: .bold, design: .rounded)
            : .system(size: 84, weight: .bold, design: .rounded)

        let sparkHeight: CGFloat = compact ? 46 : 90

        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(alignment: .top) {
                Text(cfg.avatar)
                    .font(.system(size: compact ? 34 : 46))

                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.displayName)
                        .font(compact ? .headline : .title2.weight(.semibold))
                        .lineLimit(1)

                    Text(statusLine)
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let b = rt.battery {
                        Label("\(b)%", systemImage: "battery.100")
                            .font(compact ? .caption2 : .caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let rssi = rt.rssi {
                        Text("\(rssi) dBm")
                            .font(compact ? .caption2 : .caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(bpmText).font(hrFont)

                Text("bpm")
                    .font(compact ? .headline : .title3)
                    .foregroundStyle(.secondary)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(pctText)
                        .font(compact ? .headline : .title3.weight(.semibold))
                    Text("av max \(cfg.maxHR)")
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            SparklineView(values: rt.percentHistory)
                .frame(height: sparkHeight)
                .opacity(rt.percentHistory.isEmpty ? 0.55 : 1.0)

            Spacer(minLength: compact ? 0 : 8)

            HStack {
                if let rr = rt.rrMs {
                    Label("\(rr) ms", systemImage: "waveform.path.ecg")
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label("RR —", systemImage: "waveform.path.ecg")
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("seen \(rt.lastSeenSeconds)s")
                    .font(compact ? .caption : .subheadline)
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
        .padding(compact ? 16 : 22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .shadow(radius: 10, y: 4)
    }

    private var statusLine: String {
        switch rt.state {
        case .connected:
            return rt.isStale ? "Ansluten • Signal tappad" : "Ansluten • OK"
        case .connecting:
            return "Ansluter…"
        case .scanning:
            return "Skannar…"
        case .disconnected:
            return "Frånkopplad"
        }
    }

    private var borderColor: Color {
        if rt.isStale { return .orange.opacity(0.7) }
        if rt.state == .connected { return .primary.opacity(0.08) }
        return .primary.opacity(0.05)
    }
}

// MARK: - Zone bar

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
