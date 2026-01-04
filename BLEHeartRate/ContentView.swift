// Tag 1.0.3
import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLECoordinator()

    // Coach Mode (sparas lokalt)
    @AppStorage("coachModeEnabled") private var coachModeEnabled: Bool = false

    var body: some View {
        NavigationStack {
            if coachModeEnabled {
                CoachModeView(coachModeEnabled: $coachModeEnabled)
                    .environmentObject(ble)
            } else {
                TabView {
                    DashboardView()
                        .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2") }

                    SensorsView()
                        .tabItem { Label("Sensorer", systemImage: "dot.radiowaves.left.and.right") }
                }
                .environmentObject(ble)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            coachModeEnabled = true
                        } label: {
                            Label("Coach Mode", systemImage: "eye")
                        }
                    }
                }
            }
        }
        .onAppear {
            // Poolkant: håll skärmen vaken
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Coach Mode View

private struct CoachModeView: View {
    @EnvironmentObject private var ble: BLECoordinator
    @Binding var coachModeEnabled: Bool

    // Enkel pagination om du har flera sensorer
    @State private var index: Int = 0

    var body: some View {
        let configs: [SensorConfig] = ble.sensorConfigs
        let runtimes: [UUID: SensorRuntime] = ble.runtime

        ZStack {
            Color.black.ignoresSafeArea()

            if configs.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 54))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Inga sensorer")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("Gå ur Coach Mode och lägg till sensorer.")
                        .foregroundStyle(.white.opacity(0.75))

                    Button("Avsluta Coach Mode") { coachModeEnabled = false }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                // Se till att index är inom range
                let safeIndex = min(max(index, 0), configs.count - 1)
                let cfg = configs[safeIndex]
                let rt = runtimes[cfg.id] ?? SensorRuntime()

                VStack(spacing: 18) {
                    topBar(cfg: cfg, rt: rt, count: configs.count)

                    bigNumbers(cfg: cfg, rt: rt)

                    // stor sparkline
                    SparklineView(values: rt.percentHistory)
                        .frame(height: 120)
                        .padding(.horizontal)
                        .opacity(rt.percentHistory.isEmpty ? 0.5 : 1.0)

                    // zon-bar extra tydlig
                    if let pct = rt.percentOfMax {
                        ZonePill(percent: pct, isStale: rt.isStale)
                            .padding(.horizontal)
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.white.opacity(0.12))
                            .frame(height: 56)
                            .padding(.horizontal)
                    }

                    Spacer(minLength: 0)

                    bottomControls(count: configs.count)
                }
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            // Coach Mode: ofta vill man att den reconnectar allt auto direkt
            ble.reconnectAllAuto()
        }
    }

    // MARK: UI blocks

    private func topBar(cfg: SensorConfig, rt: SensorRuntime, count: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(cfg.avatar).font(.system(size: 34))
                    Text(cfg.displayName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Text(statusLine(rt))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let b = rt.battery {
                    Text("🔋 \(b)%")
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let rssi = rt.rssi {
                    Text("\(rssi) dBm")
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text("\(index + 1)/\(count)")
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.caption)
            }
        }
        .padding(.horizontal)
    }

    private func bigNumbers(cfg: SensorConfig, rt: SensorRuntime) -> some View {
        let bpm = rt.hr
        let pct = rt.percentOfMax

        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(bpm.map(String.init) ?? "—")
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("bpm")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }

            HStack(spacing: 14) {
                Text(pct.map { "\($0)% av max \(cfg.maxHR)" } ?? "—% av max \(cfg.maxHR)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                if let rr = rt.rrMs {
                    Text("RR \(rr) ms")
                        .foregroundStyle(.white.opacity(0.75))
                        .font(.title3)
                }
            }

            Text("seen \(rt.lastSeenSeconds)s")
                .foregroundStyle(.white.opacity(0.6))
                .font(.subheadline)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private func bottomControls(count: Int) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    ble.reconnectAllAuto()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                if ble.isScanning {
                    Button {
                        ble.stopScan()
                    } label: {
                        Label("Stop Scan", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.85))
                } else {
                    Button {
                        ble.startScan()
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.85))
                }

                Button {
                    coachModeEnabled = false
                } label: {
                    Label("Exit", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.85))
            }

            if count > 1 {
                HStack(spacing: 12) {
                    Button {
                        index = max(0, index - 1)
                    } label: {
                        Label("Prev", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.85))

                    Button {
                        index = min(count - 1, index + 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.85))
                }
            }
        }
        .padding(.horizontal)
    }

    private func statusLine(_ rt: SensorRuntime) -> String {
        switch rt.state {
        case ConnectionState.connected:
            return rt.isStale ? "Ansluten • Signal tappad (under vatten?)" : "Ansluten • OK"
        case ConnectionState.connecting:
            return "Ansluter…"
        case ConnectionState.scanning:
            return "Skannar…"
        case ConnectionState.disconnected:
            return "Frånkopplad"
        }
    }
}

// MARK: - Zone pill

private struct ZonePill: View {
    let percent: Int
    let isStale: Bool

    var body: some View {
        let zone = HRZone.from(percent: percent)

        return HStack {
            Text("Zon \(zoneLabel(zone))")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.black.opacity(0.9))

            Spacer()

            Text("\(percent)%")
                .font(.title3.weight(.bold))
                .foregroundStyle(.black.opacity(0.9))

            if isStale {
                Text(" • signal?")
                    .foregroundStyle(.black.opacity(0.7))
                    .font(.title3)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(zoneColor(zone).opacity(isStale ? 0.5 : 0.95))
        )
    }

    private func zoneLabel(_ z: HRZone) -> String {
        switch z {
        case .z1: return "1"
        case .z2: return "2"
        case .z3: return "3"
        case .z4: return "4"
        case .z5: return "5"
        }
    }

    private func zoneColor(_ z: HRZone) -> Color {
        switch z {
        case .z1: return .blue
        case .z2: return .green
        case .z3: return .yellow
        case .z4: return .orange
        case .z5: return .red
        }
    }
}
