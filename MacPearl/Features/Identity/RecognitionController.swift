//
//  RecognitionController.swift
//  MacPearl
//

import Combine
import Foundation

enum RecognitionState: Equatable, Sendable {
    case idle
    case scanning(matches: Int, samples: Int)
    case processing
    case cooldown(until: Date)
    case unlocked(score: Float)
    case failed(String)

    var allowsFaceDepartureReset: Bool {
        switch self {
        case .scanning, .processing: true
        case .idle, .cooldown, .unlocked, .failed: false
        }
    }
}

struct RecognitionDiagnostics: Equatable, Sendable {
    var score: Float?
    var threshold: Float
    var matches: Int
    var samples: Int
    var latencyMilliseconds: Double?
    var cooldownUntil: Date?
}

@MainActor
final class RecognitionController: ObservableObject {
    @Published private(set) var state: RecognitionState = .idle
    @Published private(set) var diagnostics: RecognitionDiagnostics

    private let policy: RecognitionPolicy
    private var model: (any FaceEmbeddingModel)?
    private var matcher: FaceTemplateMatcher?
    private var stabilizer: MatchDecisionStabilizer
    private var recognitionID = UUID()
    private var cooldownTask: Task<Void, Never>?
    private var faceMissingSince: Date?
    private var faceDepartureHandled = false
    private var lastSampleAt: Date?

    init(policy: RecognitionPolicy = .standard) {
        self.policy = policy
        stabilizer = MatchDecisionStabilizer(policy: policy)
        diagnostics = RecognitionDiagnostics(
            score: nil,
            threshold: policy.similarityThreshold,
            matches: 0,
            samples: 0,
            latencyMilliseconds: nil,
            cooldownUntil: nil
        )
    }

    var isActive: Bool {
        switch state {
        case .idle: false
        default: true
        }
    }

    var isLocked: Bool {
        switch state {
        case .scanning, .processing, .cooldown: true
        default: false
        }
    }

    func begin(template: UserFaceTemplate, using camera: CameraSessionController) {
        do {
            recognitionID = UUID()
            cooldownTask?.cancel()
            model = try FaceEmbeddingModelProvider.load()
            matcher = try FaceTemplateMatcher(
                template: template,
                threshold: policy.similarityThreshold
            )
            resetDecisionState()
            state = .scanning(matches: 0, samples: 0)
            camera.captureRecognitionSample()
        } catch {
            state = .failed(error.localizedDescription)
            camera.finishFaceCapture()
        }
    }

    func receive(_ frame: CapturedFaceFrame, using camera: CameraSessionController) {
        guard case .scanning = state,
              let model, let matcher else { return }

        let now = Date()
        if let lastSampleAt,
           now.timeIntervalSince(lastSampleAt) < policy.minimumSampleInterval {
            camera.captureRecognitionSample()
            return
        }
        lastSampleAt = now
        state = .processing
        let requestID = recognitionID
        let clock = ContinuousClock()

        Task { [weak self] in
            do {
                let start = clock.now
                let embedding = try await Task.detached(priority: .userInitiated) {
                    let image = try FaceImagePreprocessor.alignedImage(from: frame)
                    return try model.embedding(for: image)
                }.value
                let latency = start.duration(to: clock.now)
                let result = try matcher.evaluate(embedding)
                guard let self, self.recognitionID == requestID else { return }
                self.handle(
                    result,
                    latencyMilliseconds: Self.milliseconds(latency),
                    using: camera
                )
            } catch {
                guard let self, self.recognitionID == requestID else { return }
                self.state = .failed(error.localizedDescription)
                camera.finishFaceCapture()
            }
        }
    }

    func updateFacePresence(
        _ hasFace: Bool,
        using camera: CameraSessionController,
        at date: Date = Date()
    ) {
        guard state.allowsFaceDepartureReset else {
            faceMissingSince = nil
            faceDepartureHandled = false
            return
        }
        if hasFace {
            faceMissingSince = nil
            faceDepartureHandled = false
            return
        }
        guard !faceDepartureHandled else { return }
        let missingSince = faceMissingSince ?? date
        faceMissingSince = missingSince
        guard date.timeIntervalSince(missingSince) >= policy.faceDepartureDelay else { return }

        faceDepartureHandled = true
        recognitionID = UUID()
        cooldownTask?.cancel()
        stabilizer.reset()
        lastSampleAt = nil
        diagnostics.matches = 0
        diagnostics.samples = 0
        diagnostics.cooldownUntil = nil
        state = .scanning(matches: 0, samples: 0)
        camera.captureRecognitionSample()
    }

    func cancel(using camera: CameraSessionController) {
        recognitionID = UUID()
        cooldownTask?.cancel()
        model = nil
        matcher = nil
        resetDecisionState()
        state = .idle
        camera.finishFaceCapture()
    }

    private func handle(
        _ result: MatchResult,
        latencyMilliseconds: Double,
        using camera: CameraSessionController
    ) {
        diagnostics.score = result.score
        diagnostics.latencyMilliseconds = latencyMilliseconds

        switch stabilizer.record(result, at: Date()) {
        case .pending(let matches, let samples):
            diagnostics.matches = matches
            diagnostics.samples = samples
            state = .scanning(matches: matches, samples: samples)
            camera.captureRecognitionSample()
        case .matched:
            diagnostics.matches = policy.requiredMatches
            state = .unlocked(score: result.score)
            camera.finishFaceCapture()
        case .cooldown(let until):
            diagnostics.matches = 0
            diagnostics.samples = 0
            diagnostics.cooldownUntil = until
            state = .cooldown(until: until)
            camera.finishFaceCapture()
            startCooldown(until: until, using: camera)
        }
    }

    private func startCooldown(until: Date, using camera: CameraSessionController) {
        let requestID = recognitionID
        cooldownTask?.cancel()
        cooldownTask = Task { [weak self] in
            let delay = max(0, until.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.recognitionID == requestID,
                  case .cooldown = self.state else { return }
            self.diagnostics.cooldownUntil = nil
            self.state = .scanning(matches: 0, samples: 0)
            camera.captureRecognitionSample()
        }
    }

    private func resetDecisionState() {
        stabilizer.reset()
        faceMissingSince = nil
        faceDepartureHandled = false
        lastSampleAt = nil
        diagnostics = RecognitionDiagnostics(
            score: nil,
            threshold: policy.similarityThreshold,
            matches: 0,
            samples: 0,
            latencyMilliseconds: nil,
            cooldownUntil: nil
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
