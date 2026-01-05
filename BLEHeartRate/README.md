# BLEHeartRate (iPad) — BLE Heart Rate Monitor (SwiftUI)

> **Svenska kort:** En enkel iPad-app byggd i SwiftUI som skannar, ansluter och visar puls (Heart Rate) från BLE-pulsband/pulssensorer som följer Bluetooth Heart Rate Profile.

BLEHeartRate is a SwiftUI iPad app that scans for Bluetooth Low Energy (BLE) heart rate sensors, connects, and displays live heart rate values using the standard **Heart Rate Service (0x180D)**.

## Features

- 🔎 Scan for nearby BLE heart rate sensors
- 🔗 Connect / disconnect to a selected sensor
- ❤️ Live heart rate updates (HR Measurement characteristic)
- 📶 Connection status + basic troubleshooting cues
- 🧼 Clean, simple SwiftUI UI designed for iPad use (pool deck / gym)

> **Note:** This app is intended for sports/fitness usage and does **not** provide medical diagnosis or treatment.

---

## Requirements

- Xcode (latest stable recommended)
- An iPad (recommended for BLE testing)
- A BLE heart rate sensor that supports the standard Heart Rate Service (0x180D)

> Tip: Real-world BLE testing is best on physical hardware. The iOS Simulator does not provide the same BLE environment as a real device.

---

## Getting Started

1. Clone the repo:
   ```bash
   git clone https://github.com/joab40/BLEHeartRate.git
   cd BLEHeartRate

