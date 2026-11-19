//
//  FaceCaptureGate.swift
//  MacPearl
//

import CoreGraphics
import Foundation

struct FacePoseTarget: Equatable, Sendable {
    let yawRange: ClosedRange<Double>
    let pitchRange: ClosedRange<Double>
    let rollRange: ClosedRange<Double>

    static let forward = FacePoseTarget(
        yawRange: degrees(-18)...degrees(18),
        pitchRange: degrees(-25)...degrees(25),
        rollRange: degrees(-18)...degrees(18)
    )


    static let left = FacePoseTarget(
        yawRange: degrees(15)...degrees(45),
        pitchRange: degrees(-25)...degrees(25),
        rollRange: degrees(-18)...degrees(18)
    )

    static let right = FacePoseTarget(
        yawRange: degrees(-45)...degrees(-15),
        pitchRange: degrees(-25)...degrees(25),
        rollRange: degrees(-18)...degrees(18)
    )

    private static func degrees(_ value: Double) -> Double {
        value * .pi / 180
    }
}

enum FaceCapturePose: String, CaseIterable, Hashable, Sendable {
    case forward
    case left
    case right

    var instruction: String {
        switch self {
        case .forward: "Look straight at the camera"
        case .left: "Slowly turn your face to the left"
        case .right: "Slowly turn your face to the right"
        }
    }

    var target: FacePoseTarget {
        switch self {
        case .forward: .forward
        case .left: .left
        case .right: .right
        }
    }
}

struct FaceCapturePolicy: Equatable, Sendable {
    let minimumDetectionConfidence: Float
    let minimumFaceWidth: CGFloat
    let minimumFaceHeight: CGFloat
    let maximumHorizontalCenterOffset: CGFloat
    let maximumVerticalCenterOffset: CGFloat
    let minimumCaptureQuality: Float
    let minimumLandmarkConfidence: Float
    let pose: FaceCapturePose
    let requiredPose: FacePoseTarget?
    let holdDuration: TimeInterval

    static let balanced = FaceCapturePolicy(
        minimumDetectionConfidence: 0.80,
        minimumFaceWidth: 0.22,
        minimumFaceHeight: 0.28,
        maximumHorizontalCenterOffset: 0.12,
        maximumVerticalCenterOffset: 0.15,
        minimumCaptureQuality: 0.45,
        minimumLandmarkConfidence: 0.50,
        pose: .forward,
        requiredPose: .forward,
        holdDuration: 0.75
    )

    static let recognition = FaceCapturePolicy(
        minimumDetectionConfidence: 0.80,
        minimumFaceWidth: 0.22,
        minimumFaceHeight: 0.28,
        maximumHorizontalCenterOffset: 0.12,
        maximumVerticalCenterOffset: 0.15,
        minimumCaptureQuality: 0.45,
        minimumLandmarkConfidence: 0.50,
        pose: .forward,
        requiredPose: .forward,
        // Recognition's three temporally separated matches provide stability.
        // Accept each quality-approved frame without a second holding period.
        holdDuration: 0
    )

    static func enrollment(_ pose: FaceCapturePose) -> FaceCapturePolicy {
        FaceCapturePolicy(
            minimumDetectionConfidence: 0.80,
            minimumFaceWidth: 0.22,
            minimumFaceHeight: 0.28,
            maximumHorizontalCenterOffset: 0.15,
            maximumVerticalCenterOffset: 0.15,
            minimumCaptureQuality: 0.45,
            minimumLandmarkConfidence: 0.50,
            pose: pose,
            requiredPose: pose.target,
            holdDuration: 0.50
        )
    }
}

enum FaceCaptureIssue: Equatable, Sendable {
    case noFace
    case multipleFaces
    case lowConfidence
    case tooSmall
    case offCenter
    case wrongPose(FaceCapturePose)
    case occluded
    case lowQuality
    case detectorUnavailable

    var message: String {
        switch self {
        case .noFace: "Position your face in the camera"
        case .multipleFaces: "Only one person can be visible"
        case .lowConfidence: "Make sure your face is clearly visible"
        case .tooSmall: "Move closer to the camera"
        case .offCenter: "Center your face"
        case .wrongPose(let pose): pose.instruction
        case .occluded: "Make sure your eyes, nose, and mouth are visible"
        case .lowQuality: "Hold still and improve the lighting"
        case .detectorUnavailable: "Face detection is temporarily unavailable"
        }
    }
}

enum FaceCaptureState: Equatable, Sendable {
    case searching
    case rejected(FaceCaptureIssue)
    case holding(progress: Double)
    case accepted
}

struct FaceCaptureEvaluation: Sendable {
    let state: FaceCaptureState
    let acceptedFace: DetectedFace?
}

struct CapturedFaceFrame: @unchecked Sendable {
    let image: CGImage
    let face: DetectedFace
    let capturedAt: Date
}

/// Stateful quality gate used only from the serial camera sample queue.
struct FaceCaptureGate: Sendable {
    private let policy: FaceCapturePolicy
    private var holdStartedAt: TimeInterval?
    private var hasAccepted = false
    private var lastValidTime: TimeInterval?

    init(policy: FaceCapturePolicy = .balanced) {
        self.policy = policy
    }

    mutating func evaluate(
        faces: [DetectedFace],
        at time: TimeInterval
    ) -> FaceCaptureEvaluation {
        if hasAccepted {
            return FaceCaptureEvaluation(state: .accepted, acceptedFace: nil)
        }

        if let lastValidTime, time - lastValidTime > 0.30 {
            holdStartedAt = nil
        }

        if let issue = rejectionReason(for: faces) {
            holdStartedAt = nil
            return FaceCaptureEvaluation(state: .rejected(issue), acceptedFace: nil)
        }

        guard let face = faces.first else {
            return FaceCaptureEvaluation(state: .rejected(.noFace), acceptedFace: nil)
        }

        lastValidTime = time
        let start = holdStartedAt ?? time
        holdStartedAt = start
        let progress = policy.holdDuration > 0
            ? min(max((time - start) / policy.holdDuration, 0), 1)
            : 1

        guard progress >= 1 else {
            return FaceCaptureEvaluation(
                state: .holding(progress: progress),
                acceptedFace: nil
            )
        }

        hasAccepted = true
        return FaceCaptureEvaluation(state: .accepted, acceptedFace: face)
    }

    mutating func reset() {
        holdStartedAt = nil
        hasAccepted = false
        lastValidTime = nil
    }

    private func rejectionReason(for faces: [DetectedFace]) -> FaceCaptureIssue? {
        guard !faces.isEmpty else { return .noFace }
        guard faces.count == 1, let face = faces.first else { return .multipleFaces }
        guard face.confidence >= policy.minimumDetectionConfidence else {
            return .lowConfidence
        }
        guard face.boundingBox.width >= policy.minimumFaceWidth,
              face.boundingBox.height >= policy.minimumFaceHeight else {
            return .tooSmall
        }

        let center = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        guard abs(center.x - 0.5) <= policy.maximumHorizontalCenterOffset,
              abs(center.y - 0.5) <= policy.maximumVerticalCenterOffset else {
            return .offCenter
        }

        if let requiredPose = policy.requiredPose {
            // Vision does not guarantee pitch and roll on every otherwise valid
            // observation. Yaw is required to distinguish the three enrollment
            // poses; optional axes constrain capture only when they are present.
            guard let yaw = face.yaw,
                  requiredPose.yawRange.contains(yaw),
                  face.pitch.map(requiredPose.pitchRange.contains) ?? true,
                  face.roll.map(requiredPose.rollRange.contains) ?? true else {
                return .wrongPose(policy.pose)
            }
        }

        guard face.hasRequiredLandmarks,
              let landmarkConfidence = face.landmarkConfidence,
              landmarkConfidence >= policy.minimumLandmarkConfidence else {
            return .occluded
        }

        guard let captureQuality = face.captureQuality,
              captureQuality >= policy.minimumCaptureQuality else {
            return .lowQuality
        }
        return nil
    }
}
