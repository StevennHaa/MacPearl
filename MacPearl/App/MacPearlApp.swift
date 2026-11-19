//
//  MacPearlApp.swift
//  MacPearl
//
//  Created by Steven Ha on 9/29/26.
//

import SwiftUI

@main
enum MacPearlEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--credential-self-test") {
            let interactive = CommandLine.arguments.contains("--interactive")
            exit(CredentialStorageSelfTest.run(interactive: interactive))
        }
        MacPearlApp.main()
    }
}

struct MacPearlApp: App {
    @StateObject private var session = AppSessionController()
#if DEBUG
    @Environment(\.openWindow) private var openWindow
#endif

    var body: some Scene {
        MenuBarExtra("MacPearl", systemImage: "faceid") {
            Text(session.readiness.title)
            if case .attention(let message) = session.readiness { Text(message) }
            Divider()
            Button(session.readiness == .setupRequired ? "Continue Setup…" : "Open Setup…") { session.openSetup() }
            if session.credentials.hasStoredCredential && session.credentials.status != .sessionReady {
                Button("Authorize Session") { session.requestAuthorization() }.disabled(session.credentials.isBusy)
            }
            SettingsLink { Text("Settings…") }
#if DEBUG
            Button("Developer Demo…") {
                session.closeSetup()
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "developer-demo")
            }
#endif
            Divider()
            Button("Quit MacPearl") { session.shutdown(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        Settings { MacPearlSettingsView(session: session) }
#if DEBUG
        Window("MacPearl Developer Demo", id: "developer-demo") {
            HomeView(camera: session.recognition.camera, recognition: session.recognition.recognition)
                .environmentObject(session.monitor)
                .environmentObject(session.launchAtLogin)
                .environmentObject(session.credentials)
                .environmentObject(session.recognition)
                .environmentObject(session.notch)
                .environmentObject(session)
        }.defaultLaunchBehavior(.suppressed)
#endif
    }
}
