// SensorModels.swift
// Version 1.0.24
// NOTE (Zones/Fart strategy):
// - HRZone är din “zon/fart”-källa för hela appen.
// - Gränser (% av sim-HRmax):
//   F1: 0–60   (återhämtning/badning; “snacktempo”)
//   F2: 61–75  (aerob bas)
//   F3: 76–85  (tröskel/CSS)
//   F4: 86–93  (anaerob tröskel / mjölksyratålighet)
//   F5: 94–100 (sprint/VO₂; puls trubbigt vid korta sprintar — fart/RPE/paus styr bättre)
//
// NOTE (Implementation):
// - UI visar F1–F5 via HRZone.shortLabel/name.
// - Om du vill ändra zoner i framtiden: gör det här (HRZone.from).

import Foundation
import SwiftUI

enum ConnectionState: String, Codable {
    case connected
    case connecting
    case scanning
    case disconnected
}

struct SensorConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var displayName: String
    var avatar: String
    var maxHR: Int
    var autoConnect: Bool
    var showOnDashboard: Bool

    static func `default`(id: UUID, name: String) -> SensorConfig {
        SensorConfig(
            id: id,
            displayName: name,
            avatar: "❤️",
            maxHR: 190,
            autoConnect: true,
            showOnDashboard: true
        )
    }
}

struct SensorRuntime: Equatable {
    var state: ConnectionState = .disconnected
    var statusText: String = ""

    var hr: Int? = nil
    var rrMs: Int? = nil
    var battery: Int? = nil
    var rssi: Int? = nil

    var lastHRAt: Date? = nil
    var lastSeenSeconds: Int = 0
    var isStale: Bool = false

    var percentOfMax: Int? = nil
    var percentHistory: [Int] = []

    init() {}
}

enum HRZone: Equatable {
    case z1, z2, z3, z4, z5

    static func from(percent: Int) -> HRZone {
        let p = max(0, min(100, percent))
        switch p {
        case ..<61:  return .z1       // F1: 0–60
        case 61..<76: return .z2      // F2: 61–75
        case 76..<86: return .z3      // F3: 76–85
        case 86..<94: return .z4      // F4: 86–93
        default:      return .z5      // F5: 94–100
        }
    }

    var shortLabel: String {
        switch self {
        case .z1: return "F1"
        case .z2: return "F2"
        case .z3: return "F3"
        case .z4: return "F4"
        case .z5: return "F5"
        }
    }

    var name: String {
        switch self {
        case .z1: return "Återhämtning"
        case .z2: return "Aerob bas"
        case .z3: return "Tröskel/CSS"
        case .z4: return "Anaerob tröskel"
        case .z5: return "Sprint/VO₂"
        }
    }

    var color: Color {
        switch self {
        case .z1: return .blue
        case .z2: return .green
        case .z3: return .yellow
        case .z4: return .orange
        case .z5: return .red
        }
    }
}
