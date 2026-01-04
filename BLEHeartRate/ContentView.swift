//
//  ContentView.swift
//  BLEHeartRate
//
//  Created by johan on 2026-01-03.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLECoordinator()

    var body: some View {
        NavigationStack {
            TabView {
                DashboardView()
                    .tabItem { Label("Dashboard", systemImage: "rectangle.grid.2x2") }

                SensorsView()
                    .tabItem { Label("Sensorer", systemImage: "dot.radiowaves.left.and.right") }
            }
            .environmentObject(ble)
        }
        .onAppear {
            // Bra i simhall: förhindra att skärmen släcks under pass
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
