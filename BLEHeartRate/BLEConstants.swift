//
//  BLEConstants.swift
//  BLEHeartRate
//
//  Created by johan on 2026-01-04.
//

import Foundation
import CoreBluetooth

enum BLEConstants {
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")

    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel = CBUUID(string: "2A19")
}
