import SwiftUI

struct MacPearlPreferencesView: View {
    @ObservedObject var session: AppSessionController
    @ObservedObject private var login: LaunchAtLoginController
    @AppStorage("showNotchAnimation") private var showNotchAnimation = true

    init(session: AppSessionController) { self.session = session; login = session.launchAtLogin }

    var body: some View {
        Toggle("Launch MacPearl at login", isOn: Binding(get: { login.isEnabled }, set: { login.setEnabled($0) }))
            .disabled(!session.installedForLogin)
        if !session.installedForLogin { Text("Move MacPearl to Applications first.").font(.caption) }
        Text(login.errorMessage ?? login.statusMessage).font(.caption).foregroundStyle(.secondary)
        Toggle("Show notch unlock animation", isOn: $showNotchAnimation)
    }
}

struct MacPearlSettingsView: View {
    @ObservedObject var session: AppSessionController
    @ObservedObject private var credentials: ProtectedCredentialController
    @State private var removal: Removal?
    private enum Removal: String, Identifiable {
        case password = "Remove Stored Password", face = "Delete Saved Face"
        var id: String { rawValue }
    }
    init(session: AppSessionController) { self.session = session; credentials = session.credentials }

    var body: some View {
        Form {
            Section("Status") {
                Text(session.readiness.title)
                if case .attention(let message) = session.readiness { Text(message).foregroundStyle(.orange) }
                Button("Open Setup…") { session.openSetup() }
                if session.isPaused {
                    Button("Resume Automatic Unlock…") { session.resumeAutomaticUnlock() }.disabled(credentials.isBusy)
                } else {
                    Button("Pause Automatic Unlock") { session.pauseAutomaticUnlock() }
                }
            }
            Section("Preferences") { MacPearlPreferencesView(session: session) }
            Section("Automatic Unlock") {
                Text(credentials.status.message)
                if credentials.isBusy { ProgressView() }
                if credentials.hasStoredCredential {
                    if credentials.status != .sessionReady {
                        Button("Authorize Session") { session.requestAuthorization() }.disabled(credentials.isBusy || session.isPaused)
                    }
                    Button("Update Password…") { session.updatePassword() }.disabled(credentials.isBusy)
                } else { Button(credentials.needsRepair ? "Repair Credential…" : "Set Up Password…") { session.updatePassword() } }
                Text("Authorize once per app launch. Quitting clears the authorized session. Your password is encrypted on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Remove Stored Data") {
                Button("Remove Stored Password…", role: .destructive) { removal = .password }
                    .disabled(credentials.isBusy || credentials.credentialHealth == .absent)
                Button("Delete Saved Face…", role: .destructive) { removal = .face }
                    .disabled(credentials.isBusy)
                if let message = session.removalMessage { Text(message).font(.caption) }
                Text("Removal pauses automatic unlock and clears authorization. If removing a password fails, its status appears above. Turn off launch at login before deleting MacPearl from Applications.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("MacPearl")
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))").font(.caption)
                Text("Local camera recognition for your signed-in session. Does not unlock FileVault or replace macOS authentication.").font(.caption)
            }
        }
        .formStyle(.grouped).frame(width: 500, height: 720)
        .onAppear { session.refresh() }
        .alert(item: $removal) { action in
            Alert(title: Text(action.rawValue + "?"),
                  message: Text("Automatic unlock will remain paused. Removing a face requires re-enrollment; removing a password requires setting it up again."),
                  primaryButton: .destructive(Text(action.rawValue)) {
                      switch action {
                      case .password: session.removeStoredPassword()
                      case .face: session.deleteFace()
                      }
                  }, secondaryButton: .cancel())
        }
    }
}
