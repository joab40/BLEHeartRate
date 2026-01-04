//
//  Persistence.swift
//  BLEHeartRate
//
//  Created by johan on 2026-01-04.
//

import Foundation

enum Persistence {
    private static let key = "savedSensors.v1"

    static func loadSensors() -> [SensorConfig] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([SensorConfig].self, from: data)
        } catch {
            return []
        }
    }

    static func saveSensors(_ sensors: [SensorConfig]) {
        do {
            let data = try JSONEncoder().encode(sensors)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // ignore
        }
    }
}
