// Version 1.0.16
import Foundation
import SwiftUI

enum ConnectionState: String, Codable {
    case disconnected
    case scanning
    case connecting
    case connected
}

struct SensorConfig: Identifiable, Codable, Equatable {
    let id: UUID                 // CBPeripheral.identifier
    var displayName: String
    var avatar: String           // emoji
    var maxHR: Int               // 60...230
    var autoConnect: Bool

    // ✅ kan döljas från dashboard
    var showOnDashboard: Bool = true

    static func `default`(id: UUID, name: String) -> SensorConfig {
        SensorConfig(
            id: id,
            displayName: name.isEmpty ? "Sensor" : name,
            avatar: "🫀",
            maxHR: 190,
            autoConnect: true,
            showOnDashboard: true
        )
    }

    // ✅ Backward compatible decoding
    enum CodingKeys: String, CodingKey {
        case id, displayName, avatar, maxHR, autoConnect, showOnDashboard
    }

    init(id: UUID,
         displayName: String,
         avatar: String,
         maxHR: Int,
         autoConnect: Bool,
         showOnDashboard: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.avatar = avatar
        self.maxHR = maxHR
        self.autoConnect = autoConnect
        self.showOnDashboard = showOnDashboard
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatar = try c.decode(String.self, forKey: .avatar)
        maxHR = try c.decode(Int.self, forKey: .maxHR)
        autoConnect = try c.decode(Bool.self, forKey: .autoConnect)

        // ✅ Gamla sparade configar saknar denna → default true
        showOnDashboard = try c.decodeIfPresent(Bool.self, forKey: .showOnDashboard) ?? true
    }
}

struct SensorRuntime: Equatable {
    var state: ConnectionState = .disconnected
    var statusText: String = "Frånkopplad"

    var hr: Int? = nil
    var rrMs: Int? = nil
    var battery: Int? = nil
    var rssi: Int? = nil

    var lastHRAt: Date? = nil
    var lastSeenSeconds: Int = 0

    var isStale: Bool = false
    var percentOfMax: Int? = nil

    // historik för sparkline (% av max)
    var percentHistory: [Int] = []
}

enum HRZone: CaseIterable {
    case z1, z2, z3, z4, z5

    /// Standardzoner baserat på % av maxpuls
    static func from(percent: Int) -> HRZone {
        let p = max(0, min(100, percent))
        switch p {
        case ..<60: return .z1
        case 60..<70: return .z2
        case 70..<80: return .z3
        case 80..<90: return .z4
        default: return .z5
        }
    }

    // MARK: - Presentation

    var shortLabel: String {
        switch self {
        case .z1: return "Z1"
        case .z2: return "Z2"
        case .z3: return "Z3"
        case .z4: return "Z4"
        case .z5: return "Z5"
        }
    }

    /// Zon-namn anpassade för simning (Z2 kondition, Z3 tröskel)
    var name: String {
        switch self {
        case .z1: return "Lugn"
        case .z2: return "Kondition"
        case .z3: return "Tröskel"
        case .z4: return "Hårt"
        case .z5: return "Max"
        }
    }

    /// Färger som är snygga i både light/dark och inte “skrikiga”.
    /// (Vi använder sen opacity i UI för bakgrund/ram.)
    var color: Color {
        switch self {
        case .z1: return .cyan
        case .z2: return .green
        case .z3: return .yellow
        case .z4: return .orange
        case .z5: return .pink
        }
    }
}

// MARK: - Convenience helpers (optional but nice)

extension SensorRuntime {
    /// Beräknar zon från percentOfMax om det finns.
    var zone: HRZone? {
        guard let p = percentOfMax else { return nil }
        return HRZone.from(percent: p)
    }
}
