import Foundation

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

    static func `default`(id: UUID, name: String) -> SensorConfig {
        SensorConfig(
            id: id,
            displayName: name.isEmpty ? "Sensor" : name,
            avatar: "🫀",
            maxHR: 190,
            autoConnect: true
        )
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

enum HRZone {
    case z1, z2, z3, z4, z5

    static func from(percent: Int) -> HRZone {
        switch percent {
        case ..<60: return .z1
        case 60..<70: return .z2
        case 70..<80: return .z3
        case 80..<90: return .z4
        default: return .z5
        }
    }
}
