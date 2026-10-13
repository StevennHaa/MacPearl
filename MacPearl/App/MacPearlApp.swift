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
    @StateObject private var credentialController: ProtectedCredentialController
    @StateObject private var lockedSessionRecognition: LockedSessionRecognitionCoordinator
    @StateObject private var notchOverlay: NotchUnlockOverlayController

    init() {
        let monitor = LockSessionMonitor()
        let credentials = ProtectedCredentialController()
        _lockSessionMonitor = StateObject(wrappedValue: monitor)
        _credentialController = StateObject(wrappedValue: credentials)
        let recognition = LockedSessionRecognitionCoordinator(
            lockSessionMonitor: monitor,
            credentialController: credentials
        )
        _lockedSessionRecognition = StateObject(wrappedValue: recognition)
        _notchOverlay = StateObject(wrappedValue: NotchUnlockOverlayController(monitor: monitor, recognition: recognition))
    }

    var body: some Scene {
        WindowGroup {
            HomeView(
                camera: lockedSessionRecognition.camera,
                recognition: lockedSessionRecognition.recognition
            )
                .environmentObject(lockSessionMonitor)
                .environmentObject(launchAtLogin)
                .environmentObject(credentialController)
                .environmentObject(lockedSessionRecognition)
                .environmentObject(notchOverlay)
        }
    }
}
