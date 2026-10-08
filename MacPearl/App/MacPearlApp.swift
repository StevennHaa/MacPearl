//
//  MacPearlApp.swift
//  MacPearl
//
//  Created by Steven Ha on 9/29/26.
//

import SwiftUI

@main
struct MacPearlApp: App {
    @StateObject private var lockSessionMonitor = LockSessionMonitor()
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(lockSessionMonitor)
                .environmentObject(launchAtLogin)
        }
    }
}
