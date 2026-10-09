//
//  MacPearlApp.swift
//  MacPearl
//
//  Created by Steven Ha on 9/29/26.
//

import SwiftUI

@main
struct MacPearlApp: App {
    @StateObject private var lockSessionMonitor: LockSessionMonitor
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var lockedSessionRecognition: LockedSessionRecognitionCoordinator

    init() {
        let monitor = LockSessionMonitor()
        _lockSessionMonitor = StateObject(wrappedValue: monitor)
        _lockedSessionRecognition = StateObject(
            wrappedValue: LockedSessionRecognitionCoordinator(lockSessionMonitor: monitor)
        )
    }

    var body: some Scene {
        WindowGroup {
            HomeView(
                camera: lockedSessionRecognition.camera,
                recognition: lockedSessionRecognition.recognition
            )
                .environmentObject(lockSessionMonitor)
                .environmentObject(launchAtLogin)
                .environmentObject(lockedSessionRecognition)
        }
    }
}
