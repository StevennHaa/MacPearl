import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage = "Checking…"
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            statusMessage = "Starts automatically after sign-in"
        case .requiresApproval:
            isEnabled = false
            statusMessage = "Approval required in Login Items"
        case .notRegistered:
            isEnabled = false
            statusMessage = "Disabled"
        case .notFound:
            isEnabled = false
            statusMessage = "Unavailable in this build"
        @unknown default:
            isEnabled = false
            statusMessage = "Unknown status"
        }
    }
}
