//
//  HeartRateParser.swift
//  BLEHeartRate
//
//  Created by johan on 2026-01-04.
//

import Foundation

struct HeartRateSample {
    let bpm: Int
    let rrMs: Int?
}

enum HeartRateParser {
    static func parse(_ data: Data) -> HeartRateSample? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }

        let flags = b[0]
        let hrIsUInt16 = (flags & 0x01) != 0
        let energyPresent = (flags & 0x08) != 0
        let rrPresent = (flags & 0x10) != 0

        var index = 1

        let bpm: Int
        if !hrIsUInt16 {
            bpm = Int(b[index])
            index += 1
        } else {
            guard b.count >= index + 2 else { return nil }
            let v = UInt16(b[index]) | (UInt16(b[index + 1]) << 8)
            bpm = Int(v)
            index += 2
        }

        if energyPresent {
            // skip 2 bytes
            guard b.count >= index + 2 else { return HeartRateSample(bpm: bpm, rrMs: nil) }
            index += 2
        }

        var rrMs: Int? = nil
        if rrPresent {
            // RR intervals are UInt16 in 1/1024 seconds
            if b.count >= index + 2 {
                let rr = UInt16(b[index]) | (UInt16(b[index + 1]) << 8)
                let ms = Int((Double(rr) / 1024.0) * 1000.0)
                rrMs = ms
            }
        }

        return HeartRateSample(bpm: bpm, rrMs: rrMs)
    }
}
