//
//  capricornus_iosApp.swift
//  capricornus-ios
//
//  Created by Mac on 10/5/2026.
//

import SwiftUI

@main
struct capricornus_iosApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    // Keep screen on during demo — user should set auto-lock to Never in Settings
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
