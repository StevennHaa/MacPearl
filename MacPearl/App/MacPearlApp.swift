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

    init() {
        let monitor = LockSessionMonitor()
        let credentials = ProtectedCredentialController()
        _lockSessionMonitor = StateObject(wrappedValue: monitor)
        _credentialController = StateObject(wrappedValue: credentials)
        _lockedSessionRecognition = StateObject(
            wrappedValue: LockedSessionRecognitionCoordinator(
                lockSessionMonitor: monitor,
                credentialController: credentials
            )
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
                .environmentObject(credentialController)
                .environmentObject(lockedSessionRecognition)
        }
    }
}
