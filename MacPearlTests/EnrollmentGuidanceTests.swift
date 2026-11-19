import AppKit
import SwiftUI
import XCTest
@testable import MacPearl

@MainActor
final class EnrollmentGuidanceTests: XCTestCase {
    func testTurnDirectionsFollowExistingPoseTargets() {
        XCTAssertEqual(guide(.left, yaw: 0).direction, .left)
        XCTAssertEqual(guide(.right, yaw: 0).direction, .right)
        XCTAssertEqual(guide(.left, yaw: -30).direction, .left)
        XCTAssertEqual(guide(.right, yaw: 30).direction, .right)
    }

    func testOvershootReversesCorrection() {
        XCTAssertEqual(guide(.left, yaw: 55).direction, .right)
        XCTAssertEqual(guide(.right, yaw: -55).direction, .left)
        XCTAssertEqual(guide(.forward, yaw: 30).direction, .right)
        XCTAssertEqual(guide(.forward, yaw: -30).direction, .left)
    }

    func testYawInRangeDoesNotFalselyApproveCapture() throws {
        let guidance = guide(.left, yaw: 25)
        XCTAssertNil(guidance.direction)
        XCTAssertNil(guidance.holdProgress)
        XCTAssertEqual(guidance.message, "Keep this angle")
        XCTAssertTrue(guidance.target.contains(try XCTUnwrap(guidance.position)))
    }

    func testHoldProgressComesFromQualityGate() {
        let guidance = EnrollmentGuidance.evaluate(pose: .right, faces: [face(yaw: -25)], capture: .holding(progress: 0.4))
        XCTAssertEqual(guidance.holdProgress, 0.4)
        XCTAssertEqual(guidance.message, "Hold still")
        XCTAssertNil(guidance.direction)
        let processing = EnrollmentGuidance.evaluate(pose: .right, faces: [], capture: .searching, processing: true)
        XCTAssertEqual(processing.holdProgress, 1)
        XCTAssertEqual(processing.message, "Angle captured")
    }

    func testQualityFailureOverridesTurnArrowEvenAtTargetAngle() {
        let guidance = EnrollmentGuidance.evaluate(pose: .left, faces: [face(yaw: 25)], capture: .rejected(.lowQuality))
        XCTAssertNil(guidance.direction)
        XCTAssertNil(guidance.holdProgress)
        XCTAssertNil(guidance.position)
        XCTAssertEqual(guidance.message, FaceCaptureIssue.lowQuality.message)
    }

    func testMissingMultipleAndUnknownFacesDoNotSuggestBlindTurn() {
        for faces in [[], [face(yaw: 0), face(yaw: 0)]] {
            let guidance = EnrollmentGuidance.evaluate(pose: .left, faces: faces, capture: .searching)
            XCTAssertNil(guidance.direction)
            XCTAssertNil(guidance.position)
        }
        let guidance = EnrollmentGuidance.evaluate(pose: .left, faces: [face(yaw: nil)], capture: .rejected(.wrongPose(.left)))
        XCTAssertNil(guidance.direction)
        XCTAssertNil(guidance.position)
    }

    func testCenteringUsesMirroredPreviewCoordinates() {
        let leftOfCamera = face(yaw: 25, box: CGRect(x: 0.05, y: 0.3, width: 0.3, height: 0.4))
        let rightOfCamera = face(yaw: 25, box: CGRect(x: 0.65, y: 0.3, width: 0.3, height: 0.4))
        XCTAssertEqual(EnrollmentGuidance.evaluate(pose: .left, faces: [leftOfCamera], capture: .rejected(.offCenter)).direction, .left)
        XCTAssertEqual(EnrollmentGuidance.evaluate(pose: .left, faces: [rightOfCamera], capture: .rejected(.offCenter)).direction, .right)
    }

    func testTiltCorrectionDoesNotAskForMoreYaw() {
        let guidance = EnrollmentGuidance.evaluate(pose: .left, faces: [face(yaw: 25, pitch: 40)], capture: .rejected(.wrongPose(.left)))
        XCTAssertNil(guidance.direction)
        XCTAssertEqual(guidance.message, "Keep your chin level")
    }

    func testGuidanceRendersAtOnboardingWidth() throws {
        let samples: [(FaceCapturePose, EnrollmentGuidance)] = [
            (.left, guide(.left, yaw: 0)),
            (.right, guide(.right, yaw: 0)),
            (.left, EnrollmentGuidance.evaluate(pose: .left, faces: [face(yaw: 25)], capture: .holding(progress: 0.6)))
        ]
        for (index, sample) in samples.enumerated() {
            let renderer = ImageRenderer(content: EnrollmentGuidanceView(pose: sample.0, completed: 1, guidance: sample.1)
                .frame(width: 540).padding(16).background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertGreaterThan(image.height, 0)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/private/tmp/MacPearl-Enrollment-Guidance-\(index).png"))
        }
    }

    private func guide(_ pose: FaceCapturePose, yaw: Double) -> EnrollmentGuidance {
        .evaluate(pose: pose, faces: [face(yaw: yaw)], capture: .rejected(.wrongPose(pose)))
    }
    private func face(yaw: Double?, pitch: Double? = 0,
                      box: CGRect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)) -> DetectedFace {
        DetectedFace(boundingBox: box, confidence: 1, roll: 0, yaw: yaw.map { $0 * .pi / 180 },
                     pitch: pitch.map { $0 * .pi / 180 }, captureQuality: 1, landmarkConfidence: 1,
                     hasRequiredLandmarks: true, landmarks: nil)
    }
}
