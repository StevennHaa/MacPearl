import AppKit
import AVFoundation
import Combine
import SwiftUI

enum SetupStep: Int, CaseIterable {
    case welcome, permissions, enrollment, credential, review
    var title: String {
        switch self {
        case .welcome: "Welcome to MacPearl"
        case .permissions: "Allow MacPearl access"
        case .enrollment: "Meet your Mac"
        case .credential: "Prepare automatic unlock"
        case .review: "You're almost ready"
        }
    }
}

enum AppReadiness: Equatable {
    case setupRequired, authorizationRequired, authorizing, ready, attention(String)
    var title: String {
        switch self {
        case .setupRequired: "Setup incomplete"
        case .authorizationRequired: "Authorization required"
        case .authorizing: "Authorizing…"
        case .ready: "Ready to unlock"
        case .attention: "Needs attention"
        }
    }

    static func evaluate(completed: Bool, hasFace: Bool, camera: Bool, accessibility: Bool,
                         stored: Bool, credentials: ProtectedCredentialStatus) -> Self {
        guard completed, hasFace, stored else { return .setupRequired }
        guard camera else { return .attention("Allow Camera access in System Settings.") }
        guard accessibility else { return .attention("Allow Accessibility access in System Settings.") }
        switch credentials {
        case .sessionReady: return .ready
        case .working: return .authorizing
        case .failed(let message): return .attention(message)
        default: return .authorizationRequired
        }
    }
}

@MainActor
final class AppSessionController: ObservableObject {
    let monitor: LockSessionMonitor
    let credentials: ProtectedCredentialController
    let recognition: LockedSessionRecognitionCoordinator
    let enrollment: EnrollmentController
    let launchAtLogin: LaunchAtLoginController
    let notch: NotchUnlockOverlayController

    @Published private(set) var readiness: AppReadiness = .setupRequired
    @Published private(set) var step: SetupStep = .welcome
    @Published private(set) var cameraGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var setupVisible = false
    @Published private(set) var setupSuspended = false
    @Published private(set) var authorizationOnly = false
    @Published private(set) var isUpdatingPassword = false
    @Published private(set) var passwordDraftGeneration = 0
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var requestedLaunchAuthorization = false
    private var completed: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completed = defaults.bool(forKey: "setupCompleted")
        monitor = LockSessionMonitor()
        credentials = ProtectedCredentialController()
        enrollment = EnrollmentController()
        launchAtLogin = LaunchAtLoginController()
        recognition = LockedSessionRecognitionCoordinator(lockSessionMonitor: monitor, credentialController: credentials)
        recognition.setAutomaticUnlockEnabled(false)
        notch = NotchUnlockOverlayController(monitor: monitor, recognition: recognition)
        installBindings()
        refresh()
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    var hasFace: Bool { enrollment.template != nil }
    var canFinish: Bool {
        cameraGranted && accessibilityGranted && hasFace && credentials.status == .sessionReady
    }
    var canContinue: Bool {
        switch step {
        case .welcome: true
        case .permissions: cameraGranted && accessibilityGranted
        case .enrollment: hasFace
        case .credential, .review: canFinish
        }
    }
    var installedForLogin: Bool {
#if DEBUG
        true
#else
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
#endif
    }

    private func installBindings() {
        credentials.$isBusy.removeDuplicates().sink { [weak self] busy in
            self?.notch.setCredentialAuthorizationInProgress(busy)
        }.store(in: &subscriptions)
        credentials.objectWillChange.merge(with: enrollment.objectWillChange)
            .sink { [weak self] _ in
                // ObservableObject publishes before assignment; read next turn.
                DispatchQueue.main.async { self?.refresh() }
            }.store(in: &subscriptions)
        recognition.camera.$capturedFace.compactMap { $0 }
            .sink { [weak self] frame in
                guard let self, self.setupVisible, !self.setupSuspended,
                      self.step == .enrollment, !self.recognition.isLockedSessionActive else { return }
                self.enrollment.receive(frame, using: self.recognition.camera)
            }.store(in: &subscriptions)
        monitor.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            if snapshot.isLocked || snapshot.isSleeping || snapshot.lastEvent == .screenLocked || snapshot.lastEvent == .willSleep {
                self.suspendSetup()
            } else if snapshot.lastEvent == .screenUnlocked {
                DispatchQueue.main.async { self.refresh(); self.start() }
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification))
            .sink { [weak self] _ in self?.refresh(); self?.start() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.shutdown() }.store(in: &subscriptions)
    }

    func refresh() {
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        accessibilityGranted = AccessibilityLoginUnlocker.isTrusted
        readiness = AppReadiness.evaluate(completed: completed, hasFace: hasFace, camera: cameraGranted,
                                         accessibility: accessibilityGranted, stored: credentials.hasStoredCredential,
                                         credentials: credentials.status)
        recognition.setAutomaticUnlockEnabled(readiness == .ready && (!setupVisible || setupSuspended))
        if hasFace { recognition.refreshTemplate() }
        launchAtLogin.refresh()
        if authorizationOnly, credentials.status == .sessionReady { closeSetup() }
    }

    func start() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        guard LockSessionMonitor.currentLockState() == false else { return }
        if !started {
            started = true
            if !completed { openSetup(); return }
        }
        guard completed, hasFace, cameraGranted, accessibilityGranted,
              credentials.hasStoredCredential, !requestedLaunchAuthorization,
              !credentials.isBusy, credentials.status != .sessionReady else { return }
        requestedLaunchAuthorization = true
        requestAuthorization()
    }

    func openSetup() {
        credentials.cancelAuthorization()
        stopEnrollment()
        passwordDraftGeneration += 1
        isUpdatingPassword = credentials.needsRepair
        authorizationOnly = false
        if !completed { step = .welcome }
        else if !cameraGranted || !accessibilityGranted { step = .permissions }
        else if !hasFace { step = completed ? .enrollment : .welcome }
        else if credentials.status != .sessionReady { step = .credential }
        else { step = .review }
        presentSetup()
    }

    func requestAuthorization() {
        guard credentials.hasStoredCredential else { openSetup(); return }
        guard LockSessionMonitor.currentLockState() == false else { return }
        stopEnrollment()
        passwordDraftGeneration += 1
        isUpdatingPassword = false
        requestedLaunchAuthorization = true
        authorizationOnly = completed
        step = .credential
        presentSetup()
        credentials.prepareSession()
    }

    func updatePassword() {
        guard LockSessionMonitor.currentLockState() == false else { return }
        credentials.clearSession()
        stopEnrollment()
        passwordDraftGeneration += 1
        isUpdatingPassword = true
        authorizationOnly = completed
        step = .credential
        presentSetup()
    }

    private func presentSetup() {
        guard LockSessionMonitor.currentLockState() == false else {
            setupSuspended = true
            return
        }
        setupVisible = true
        setupSuspended = false
        recognition.setAutomaticUnlockEnabled(false)
        notch.presentOnboarding(AnyView(MacPearlOnboardingView(session: self))) { [weak self] in self?.closeSetup() }
    }

    func closeSetup() {
        credentials.cancelAuthorization()
        stopEnrollment()
        passwordDraftGeneration += 1
        setupVisible = false
        setupSuspended = false
        authorizationOnly = false
        isUpdatingPassword = false
        notch.dismissOnboarding()
        refresh()
    }

    private func suspendSetup() {
        guard setupVisible, !setupSuspended else { return }
        credentials.cancelAuthorization()
        stopEnrollment(reload: false)
        passwordDraftGeneration += 1
        setupSuspended = true
        notch.dismissOnboarding()
        refresh()
    }

    func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func requestAccessibility() {
        _ = AccessibilityLoginUnlocker.promptForPermission()
        refresh()
    }

    func beginEnrollment() {
        guard step == .enrollment, setupVisible, !setupSuspended,
              LockSessionMonitor.currentLockState() == false, cameraGranted else { return }
        recognition.setPreviewVisible(true)
        enrollment.begin(using: recognition.camera)
    }

    private func stopEnrollment(reload: Bool = true) {
        if enrollment.isActive { enrollment.cancel(using: recognition.camera) }
        recognition.setPreviewVisible(false)
        if reload, LockSessionMonitor.currentLockState() == false { enrollment.reloadTemplate() }
    }

    func advance() {
        guard canContinue else { return }
        if step == .review { finishSetup(); return }
        if step == .enrollment { stopEnrollment() }
        var next = SetupStep(rawValue: step.rawValue + 1) ?? .review
        if next == .permissions, cameraGranted && accessibilityGranted { next = .enrollment }
        if next == .enrollment, hasFace { next = .credential }
        if next == .credential, credentials.status == .sessionReady { next = .review }
        step = next
        passwordDraftGeneration += 1
    }

    func back() {
        guard step != .welcome else { return }
        credentials.cancelAuthorization()
        stopEnrollment()
        step = SetupStep(rawValue: step.rawValue - 1) ?? .welcome
        passwordDraftGeneration += 1
    }

    private func finishSetup() {
        guard canFinish else { return }
        completed = true
        defaults.set(true, forKey: "setupCompleted")
        closeSetup()
    }

    func shutdown() {
        credentials.clearSession()
        stopEnrollment(reload: false)
        recognition.setAutomaticUnlockEnabled(false)
        recognition.camera.stop()
        notch.dismissOnboarding()
    }
}
