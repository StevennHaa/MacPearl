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
    init(session: AppSessionController) { self.session = session; credentials = session.credentials }

    var body: some View {
        Form {
            Section("Status") {
                Text(session.readiness.title)
                if case .attention(let message) = session.readiness { Text(message).foregroundStyle(.orange) }
                Button("Open Setup…") { session.openSetup() }
            }
            Section("Preferences") { MacPearlPreferencesView(session: session) }
            Section("Automatic Unlock") {
                Text(credentials.status.message)
                if credentials.isBusy { ProgressView() }
                if credentials.hasStoredCredential {
                    if credentials.status != .sessionReady {
                        Button("Authorize Session") { session.requestAuthorization() }.disabled(credentials.isBusy)
                    }
                    Button("Update Password…") { session.updatePassword() }.disabled(credentials.isBusy)
                } else { Button(credentials.needsRepair ? "Repair Credential…" : "Set Up Password…") { session.updatePassword() } }
                Text("Authorize once per app launch. Quitting clears the authorized session. Your password is encrypted on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("MacPearl")
                Text("Local camera recognition for your signed-in session. Does not unlock FileVault or replace macOS authentication.").font(.caption)
            }
        }
        .formStyle(.grouped).frame(width: 500, height: 580)
        .onAppear { session.refresh() }
    }
}
