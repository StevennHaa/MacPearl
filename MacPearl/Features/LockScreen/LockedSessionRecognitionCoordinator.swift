import Combine
import Foundation
import OSLog

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
            "Face recognized; no password action was performed"
        case .failed(let message):
            message
        }
    }
}

@MainActor
final class LockedSessionRecognitionCoordinator: ObservableObject {
    @Published private(set) var status: LockedSessionRecognitionStatus = .ready
    @Published private(set) var isLockedSessionActive = false

    let camera: CameraSessionController
    let recognition: RecognitionController

    private let lockSessionMonitor: LockSessionMonitor
    private let templateStore: any FaceTemplateStoring
    private var template: UserFaceTemplate?
    private var lifecycle = LockedSessionRecognitionLifecycle()
    private var subscriptions: Set<AnyCancellable> = []
    private var isPreviewVisible = false
    private let logger = Logger(
        subsystem: "com.stevenha.MacPearl",
        category: "locked-session-recognition"
    )

    init(
        lockSessionMonitor: LockSessionMonitor,
        camera: CameraSessionController? = nil,
        recognition: RecognitionController? = nil,
        templateStore: (any FaceTemplateStoring)? = nil
    ) {
        self.lockSessionMonitor = lockSessionMonitor
        self.camera = camera ?? CameraSessionController()
        self.recognition = recognition ?? RecognitionController()
        self.templateStore = templateStore ?? KeychainFaceTemplateStore()

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
        lockSessionMonitor.$snapshot
            .combineLatest(lockSessionMonitor.$lockedSessionReadyGeneration)
            .sink { [weak self] _, _ in
                self?.reconcile()
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

    private func reconcile() {
        let snapshot = lockSessionMonitor.snapshot
        let decision = lifecycle.reconcile(
            snapshot: snapshot,
            readyGeneration: lockSessionMonitor.lockedSessionReadyGeneration,
            hasTemplate: template != nil
        )

        switch decision {
        case .start:
            guard let template else {
                status = .missingTemplate
                return
            }
            isLockedSessionActive = true
            logger.info("Starting locked-session recognition")
            camera.start()
            recognition.begin(template: template, using: camera)
        case .stop:
            logger.info("Stopping locked-session recognition")
            isLockedSessionActive = false
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
            status = .recognized(score: score)
            logger.info("Locked-session face recognized; no unlock action performed")
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
