import Foundation
import CoreGraphics

/// Presentation only. The capture gate remains the authority for pose/quality
/// acceptance; a matching yaw alone must never display a successful capture.
struct EnrollmentGuidance: Equatable {
    enum Direction: Equatable {
        case left, right, up, down
        var symbol: String {
            switch self {
            case .left: "arrow.left"
            case .right: "arrow.right"
            case .up: "arrow.up"
            case .down: "arrow.down"
            }
        }
    }
    let direction: Direction?
    let message: String
    let detail: String
    let position: Double?
    let target: ClosedRange<Double>
    let holdProgress: Double?

    // Positive Vision yaw is the existing left-pose target. The enrollment
    // preview is mirrored: positive yaw is drawn to the left of the center.
    nonisolated static func position(for yaw: Double) -> Double {
        min(max(0.5 - yaw / (120 * .pi / 180), 0), 1)
    }

    static func evaluate(pose: FaceCapturePose, faces: [DetectedFace],
                         capture: FaceCaptureState, processing: Bool = false) -> Self {
        let range = position(for: pose.target.yawRange.upperBound)...position(for: pose.target.yawRange.lowerBound)
        let face = faces.count == 1 ? faces.first : nil
        let yaw = face?.yaw.flatMap { $0.isFinite ? $0 : nil }
        let dot = yaw.map(position)
        func result(_ message: String, _ detail: String, direction: Direction? = nil,
                    progress: Double? = nil, showPosition: Bool = true) -> Self {
            Self(direction: direction, message: message, detail: detail,
                 position: showPosition ? dot : nil, target: range, holdProgress: progress)
        }
        if processing || capture == .accepted {
            return result("Angle captured", "Preparing your next pose…", progress: 1)
        }
        guard faces.count == 1 else {
            return result(faces.isEmpty ? "Bring your face into view" : "Only one face at a time",
                          "Keep your whole face inside the camera preview.", showPosition: false)
        }
        if case .holding(let progress) = capture {
            return result("Hold still", "That’s the right angle. Keep looking this way.",
                          progress: min(max(progress, 0), 1))
        }
        if case .rejected(let issue) = capture {
            switch issue {
            case .wrongPose:
                break // Resolve the actual correction below, including overshoot.
            case .offCenter:
                if let face {
                    let policy = FaceCapturePolicy.enrollment(pose)
                    let mirroredX = 1 - face.boundingBox.midX
                    if mirroredX < 0.5 - policy.maximumHorizontalCenterOffset {
                        return result("Move a little to your right", "Move your position; keep your head at this angle.", direction: .right)
                    }
                    if mirroredX > 0.5 + policy.maximumHorizontalCenterOffset {
                        return result("Move a little to your left", "Move your position; keep your head at this angle.", direction: .left)
                    }
                    return result(face.boundingBox.midY < 0.5 ? "Move your face up a little" : "Move your face down a little",
                                  "Keep your face centered in the preview.", direction: face.boundingBox.midY < 0.5 ? .up : .down)
                }
            default:
                return result(issue.message, "We’ll guide your turn once the camera has a clear view.", showPosition: false)
            }
        }
        guard let yaw else {
            return result("Look toward the camera", "Keep your face visible so we can track your turn.", showPosition: false)
        }
        let target = pose.target
        if yaw < target.yawRange.lowerBound {
            return result(pose == .right ? "Turn back a little to your left" : "Slowly turn your head left",
                          "Turn your head toward the arrow; keep your shoulders still.", direction: .left)
        }
        if yaw > target.yawRange.upperBound {
            return result(pose == .left ? "Turn back a little to your right" : "Slowly turn your head right",
                          "Turn your head toward the arrow; keep your shoulders still.", direction: .right)
        }
        if let pitch = face?.pitch, !target.pitchRange.contains(pitch) {
            return result("Keep your chin level", "Keep this turn, but look level with the camera.")
        }
        if let roll = face?.roll, !target.rollRange.contains(roll) {
            return result("Keep your head upright", "Keep this turn without tilting toward your shoulder.")
        }
        return result("Keep this angle", "Keep your face clear and steady while tracking catches up.")
    }
}
