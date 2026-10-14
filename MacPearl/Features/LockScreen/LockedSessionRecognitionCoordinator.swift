import Combine
import Foundation
import OSLog

struct LockedSessionAttemptBudget: Sendable {
    private(set) var hasAttempted = false
    private var handledUnlockCount = 0

    mutating func update(snapshot: LockSessionSnapshot) -> Bool {
        guard snapshot.confirmedUnlockCount > handledUnlockCount else { return false }
        handledUnlockCount = snapshot.confirmedUnlockCount
        hasAttempted = false
        return true
    }

    mutating func reserve() -> Bool {
        guard !hasAttempted else { return false }
        hasAttempted = true
        return true
    }
}

enum LockedSessionRecognitionDecision: Equatable, Sendable {
    case none
    case start
    case stop
    case missingTemplate
}

struct LockedSessionRecognitionLifecycle: Sendable {
    private(set) var isActive = false
    private(set) var handledGeneration = 0
    private var waitingForTemplate = false

    mutating func reconcile(
        snapshot: LockSessionSnapshot,
        readyGeneration: Int,
        hasTemplate: Bool
    ) -> LockedSessionRecognitionDecision {
        guard snapshot.isLocked, !snapshot.isSleeping else {
            waitingForTemplate = false
            guard isActive else { return .none }
            isActive = false
            return .stop
        }

        let hasNewReadyEvent = readyGeneration > handledGeneration
        guard hasNewReadyEvent || (waitingForTemplate && hasTemplate) else {
            return .none
        }

        handledGeneration = max(handledGeneration, readyGeneration)
        // Lock, display-wake, and system-wake notifications may all confirm
        // the same locked session. Consume newer generations without
        // restarting an already active camera and recognition pipeline.
        guard !isActive else { return .none }

        guard hasTemplate else {
            isActive = false
            waitingForTemplate = true
            return .missingTemplate
        }

        waitingForTemplate = false
        isActive = true
        return .start
    }
}

enum LockedSessionRecognitionStatus: Equatable, Sendable {
    case ready
    case missingTemplate
    case sleeping
    case scanning(matches: Int, samples: Int)
    case processing
    case cooldown(until: Date)
    case recognized(score: Float)
    case unlocking
    case unlockFailed(String)
    case failed(String)

    var message: String {
        switch self {
        case .ready:
            "Ready for the next locked session"
        case .missingTemplate:
            "Enroll while signed in before using locked-session recognition"
        case .sleeping:
            "Paused while the Mac is sleeping"
        case .scanning(let matches, _):
            "Locked-session recognition: \(matches) verified matches"
        case .processing:
            "Comparing the detected face"
        case .cooldown:
            "Recognition paused after failed samples"
        case .recognized:
            "Face recognized; prepare automatic unlock to continue"
        case .unlocking:
            "Entering the password through the authorized lock screen"
        case .unlockFailed(let message):
            message
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class LockedSessionRecognitionCoordinator: ObservableObject {
    @Published private(set) var status: LockedSessionRecognitionStatus = .ready
    @Published private(set) var isLockedSessionActive = false
    @Published private(set) var lastUnlockAttemptMessage: String?

    let camera: CameraSessionController
    let recognition: RecognitionController

    var handledReadyGeneration: Int { lifecycle.handledGeneration }

    private let lockSessionMonitor: LockSessionMonitor
    private let templateStore: any FaceTemplateStoring
    private let credentialController: ProtectedCredentialController
    private let unlocker: any LoginUnlocking
    private var template: UserFaceTemplate?
    private var lifecycle = LockedSessionRecognitionLifecycle()
    private var subscriptions: Set<AnyCancellable> = []
    private var isPreviewVisible = false
    private var attemptBudget = LockedSessionAttemptBudget()
    private var unlockAttemptedForSession: Bool { attemptBudget.hasAttempted }
    private var scanStartTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var lastCaptureIssue: FaceCaptureIssue?
    private var automaticUnlockEnabled = true

    func setAutomaticUnlockEnabled(_ enabled: Bool) {
        automaticUnlockEnabled = enabled
        if !enabled {
            scanStartTask?.cancel()
            unlockTask?.cancel()
            if isLockedSessionActive {
                recognition.cancel(using: camera)
                isLockedSessionActive = false
                if !isPreviewVisible { camera.stop() }
            }
        }
    }
    private let logger = Logger(
        subsystem: "com.stevenha.MacPearl",
        category: "locked-session-recognition"
    )

    init(
        lockSessionMonitor: LockSessionMonitor,
        camera: CameraSessionController? = nil,
        recognition: RecognitionController? = nil,
        templateStore: (any FaceTemplateStoring)? = nil,
        credentialController: ProtectedCredentialController? = nil,
        unlocker: (any LoginUnlocking)? = nil
    ) {
        self.lockSessionMonitor = lockSessionMonitor
        self.camera = camera ?? CameraSessionController()
        self.recognition = recognition ?? RecognitionController()
        self.templateStore = templateStore ?? KeychainFaceTemplateStore()
        self.credentialController = credentialController ?? ProtectedCredentialController()
        self.unlocker = unlocker ?? AccessibilityLoginUnlocker()

        if !lockSessionMonitor.snapshot.isLocked {
            loadTemplate()
        }
        installBindings()
        reconcile()
    }

    func setPreviewVisible(_ isVisible: Bool) {
        isPreviewVisible = isVisible
        if isVisible {
            camera.start()
        } else if !isLockedSessionActive {
            camera.stop()
        }
    }

    func refreshTemplate() {
        guard !lockSessionMonitor.snapshot.isLocked else { return }
        loadTemplate()
        reconcile()
    }

    private func installBindings() {
        camera.$faceCaptureState
            .sink { [weak self] state in
                guard let self, self.isLockedSessionActive else { return }
                if case .rejected(let issue) = state {
                    if self.lastCaptureIssue != issue {
                        self.logger.debug("Locked-session capture waiting: \(issue.message, privacy: .public)")
                    }
                    self.lastCaptureIssue = issue
                } else if case .accepted = state {
                    self.lastCaptureIssue = nil
                }
            }
            .store(in: &subscriptions)

        lockSessionMonitor.$snapshot
            .combineLatest(lockSessionMonitor.$lockedSessionReadyGeneration)
            .sink { [weak self] snapshot, readyGeneration in
                // @Published emits before assigning its property. Reading the
                // monitor here would use the previous lock state/generation.
                self?.reconcile(snapshot: snapshot, readyGeneration: readyGeneration)
            }
            .store(in: &subscriptions)

        recognition.$state
            .sink { [weak self] state in
                self?.recognitionStateChanged(state)
            }
            .store(in: &subscriptions)

        camera.$capturedFace
            .compactMap { $0 }
            .sink { [weak self] frame in
                guard let self, self.isLockedSessionActive else { return }
                self.recognition.receive(frame, using: self.camera)
            }
            .store(in: &subscriptions)

        camera.$faceDetectionResult
            .sink { [weak self] result in
                guard let self, self.isLockedSessionActive else { return }
                self.recognition.updateFacePresence(
                    !result.faces.isEmpty,
                    using: self.camera
                )
            }
            .store(in: &subscriptions)
    }

    private func reconcile(
        snapshot suppliedSnapshot: LockSessionSnapshot? = nil,
        readyGeneration suppliedGeneration: Int? = nil
    ) {
        let snapshot = suppliedSnapshot ?? lockSessionMonitor.snapshot
        if attemptBudget.update(snapshot: snapshot) {
            unlocker.reset()
        }
        // Preserve the ready generation while setup owns the camera.
        if snapshot.isLocked, !automaticUnlockEnabled { return }
        let decision = lifecycle.reconcile(
            snapshot: snapshot,
            readyGeneration: suppliedGeneration ?? lockSessionMonitor.lockedSessionReadyGeneration,
            hasTemplate: template != nil
        )

        switch decision {
        case .start:
            guard automaticUnlockEnabled else { break }
            guard let template else {
                status = .missingTemplate
                return
            }
            isLockedSessionActive = true
            lastCaptureIssue = nil
            lastUnlockAttemptMessage = "Starting face recognition for this lock session."
            guard !unlockAttemptedForSession else {
                status = .unlockFailed("A password attempt was already made. Unlock manually before trying again.")
                lastUnlockAttemptMessage = status.message
                break
            }
            logger.info("Starting locked-session recognition")
            camera.start()
            scanStartTask?.cancel()
            scanStartTask = Task { [weak self] in
                // Warm the camera while the confirmed lock transition settles.
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self,
                      self.isLockedSessionActive,
                      !self.lockSessionMonitor.snapshot.isSleeping else { return }
                // Scanning has already been triggered by a verified lock state.
                // A second transient lookup must not silently strand the scan;
                // the unlocker verifies live state before any password events.
                self.logger.info("Locked-session face scanning began after transition delay")
                self.lastUnlockAttemptMessage = "Scanning for your face."
                self.recognition.begin(template: template, using: self.camera)
            }
        case .stop:
            logger.info("Stopping locked-session recognition")
            isLockedSessionActive = false
            scanStartTask?.cancel()
            unlockTask?.cancel()
            if case .unlocking = status, !snapshot.isLocked {
                lastUnlockAttemptMessage = "macOS reported that the screen unlocked."
            } else if !unlockAttemptedForSession {
                let reason = lastCaptureIssue?.message ?? "No stable face match was completed."
                lastUnlockAttemptMessage = "Scan stopped before password entry: \(reason)"
            }
            recognition.cancel(using: camera)
            if !isPreviewVisible { camera.stop() }
        case .missingTemplate:
            isLockedSessionActive = false
            status = .missingTemplate
            logger.notice("Locked-session recognition skipped because no template was preloaded")
        case .none:
            break
        }

        if snapshot.isSleeping {
            status = .sleeping
        } else if !snapshot.isLocked {
            if case .stop = decision {
                loadTemplate()
            }
            status = template == nil ? .missingTemplate : .ready
        }
    }

    private func recognitionStateChanged(_ state: RecognitionState) {
        guard isLockedSessionActive else { return }
        switch state {
        case .idle:
            break
        case .scanning(let matches, let samples):
            status = .scanning(matches: matches, samples: samples)
        case .processing:
            status = .processing
        case .cooldown(let until):
            status = .cooldown(until: until)
        case .unlocked(let score):
            guard automaticUnlockEnabled else { return }
            guard !unlockAttemptedForSession else { return }
            guard case .sessionReady = credentialController.status else {
                status = .recognized(score: score)
                lastUnlockAttemptMessage = "Face recognized, but the credential session was not authorized."
                logger.notice("Face recognized but automatic unlock was not armed")
                return
            }
            guard attemptBudget.reserve() else { return }
            unlockTask = Task { [weak self] in
                guard let self,
                      let password = self.credentialController.withCachedPassword({ $0 }) else { return }
                self.status = .unlocking
                let result = await self.unlocker.unlock(password: password)
                guard !Task.isCancelled, self.isLockedSessionActive else { return }
                switch result {
                case .entered:
                    self.lastUnlockAttemptMessage = "Password submitted; waiting for macOS to unlock."
                    self.logger.info("Face recognized; password entry was submitted to the lock screen")
                    // Posting events has no delivery acknowledgement. Report the
                    // actual outcome without submitting the password repeatedly.
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, self.isLockedSessionActive else { return }
                    if LockSessionMonitor.currentLockState() == true {
                        let message = "Password entry was sent, but macOS is still locked."
                        self.status = .unlockFailed(message)
                        self.lastUnlockAttemptMessage = message
                        self.logger.notice("Password submission did not unlock macOS within three seconds")
                        self.credentialController.requirePasswordVerification()
                    }
                case .rejected(let message):
                    self.status = .unlockFailed(message)
                    self.lastUnlockAttemptMessage = message
                    self.logger.error("Automatic unlock was rejected: \(message, privacy: .public)")
                }
            }
        case .failed(let message):
            status = .failed(message)
            logger.error("Locked-session recognition failed: \(message, privacy: .public)")
        }
    }

    private func loadTemplate() {
        do {
            template = try templateStore.load()
        } catch {
            template = nil
            status = .failed(error.localizedDescription)
            logger.error("Could not preload face template: \(error.localizedDescription, privacy: .public)")
        }
    }
}
