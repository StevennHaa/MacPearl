import CoreGraphics
import CoreImage
import XCTest
@testable import MacPearl

final class Phase4RecognitionTests: XCTestCase {
    func testMatcherUsesForwardWeightedMultiPoseReference() throws {
        let forward = try axisEmbedding(0)
        let template = UserFaceTemplate(
            id: UUID(),
            createdAt: Date(),
            model: FaceEmbeddingModelProvider.metadata,
            preprocessingVersion: FaceImagePreprocessor.version,
            embeddings: [
                .forward: forward,
                .left: try axisEmbedding(1),
                .right: try axisEmbedding(2)
            ]
        )
        let matcher = try FaceTemplateMatcher(template: template, threshold: 0.80)

        XCTAssertEqual(try matcher.evaluate(forward).score, 0.9045, accuracy: 0.001)
        XCTAssertTrue(try matcher.evaluate(forward).isMatch)
        XCTAssertFalse(try matcher.evaluate(axisEmbedding(1)).isMatch)
    }

    func testIlluminationExposureAdjustmentIsBounded() {
        XCTAssertEqual(
            FaceImagePreprocessor.exposureAdjustment(forLuminance: 0.50),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FaceImagePreprocessor.exposureAdjustment(forLuminance: 0.25),
            2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            FaceImagePreprocessor.exposureAdjustment(forLuminance: 1.0),
            -2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            FaceImagePreprocessor.exposureAdjustment(forLuminance: 0.01),
            FaceImagePreprocessor.maximumExposureAdjustment,
            accuracy: 0.001
        )
    }

    func testIlluminationNormalizationMovesDarkInputTowardTarget() throws {
        let input = CIImage(
            color: CIColor(red: 0.25, green: 0.25, blue: 0.25)
        ).cropped(to: CGRect(origin: .zero, size: FaceImagePreprocessor.outputSize))
        let normalized = try FaceImagePreprocessor.normalizeIllumination(in: input)

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            normalized,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 56, y: 56, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        XCTAssertEqual(
            CGFloat(pixel[0]) / 255,
            FaceImagePreprocessor.targetLuminance,
            accuracy: 0.03
        )
    }

    func testThreeOfFourMatchesUnlocksDespiteOneMiss() {
        let policy = testPolicy()
        var stabilizer = MatchDecisionStabilizer(policy: policy)
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(stabilizer.record(result(true), at: start), .pending(matches: 1, samples: 1))
        XCTAssertEqual(stabilizer.record(result(false), at: start.addingTimeInterval(0.2)), .pending(matches: 1, samples: 2))
        XCTAssertEqual(stabilizer.record(result(true), at: start.addingTimeInterval(0.4)), .pending(matches: 2, samples: 3))
        XCTAssertEqual(stabilizer.record(result(true), at: start.addingTimeInterval(0.6)), .matched)
    }

    func testExpiredSamplesDoNotCount() {
        let policy = testPolicy()
        var stabilizer = MatchDecisionStabilizer(policy: policy)
        let start = Date(timeIntervalSince1970: 100)
        _ = stabilizer.record(result(true), at: start)
        _ = stabilizer.record(result(true), at: start.addingTimeInterval(0.2))

        XCTAssertEqual(
            stabilizer.record(result(true), at: start.addingTimeInterval(2.5)),
            .pending(matches: 1, samples: 1)
        )
    }

    func testFiveFailuresStartsCooldownAndClearsHistory() {
        let policy = testPolicy()
        var stabilizer = MatchDecisionStabilizer(policy: policy)
        let start = Date(timeIntervalSince1970: 100)
        for index in 0..<4 {
            _ = stabilizer.record(result(false), at: start.addingTimeInterval(Double(index) * 0.2))
        }
        let failureTime = start.addingTimeInterval(0.8)
        XCTAssertEqual(
            stabilizer.record(result(false), at: failureTime),
            .cooldown(until: failureTime.addingTimeInterval(3))
        )
        XCTAssertTrue(stabilizer.observations.isEmpty)
        XCTAssertEqual(stabilizer.consecutiveFailures, 0)
    }

    func testTemplateCodecRoundTripsSchemaTwo() throws {
        let embedding = try axisEmbedding(0)
        let template = UserFaceTemplate(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 123),
            model: FaceEmbeddingModelProvider.metadata,
            preprocessingVersion: FaceImagePreprocessor.version,
            embeddings: [.forward: embedding, .left: embedding, .right: embedding]
        )
        let codec = FaceTemplateCodec()
        XCTAssertEqual(try codec.decode(codec.encode(template)), template)
    }

    func testTemplateCodecRejectsSchemaOneBeforeDecodingBody() {
        let data = Data(#"{"schemaVersion":1}"#.utf8)
        XCTAssertThrowsError(try FaceTemplateCodec().decode(data)) { error in
            XCTAssertEqual(error as? FaceTemplateStoreError, .unsupportedVersion(1))
        }
    }

    func testTemplateCodecRejectsOlderPreprocessingVersion() throws {
        let embedding = try axisEmbedding(0)
        let template = UserFaceTemplate(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 123),
            model: FaceEmbeddingModelProvider.metadata,
            preprocessingVersion: FaceImagePreprocessor.version,
            embeddings: [.forward: embedding, .left: embedding, .right: embedding]
        )
        let codec = FaceTemplateCodec()
        let currentJSON = String(decoding: try codec.encode(template), as: UTF8.self)
        let oldJSON = currentJSON.replacingOccurrences(
            of: FaceImagePreprocessor.version,
            with: "insightface-five-point-v1"
        )

        XCTAssertThrowsError(try codec.decode(Data(oldJSON.utf8))) { error in
            XCTAssertEqual(
                error as? FaceTemplateStoreError,
                .incompatiblePreprocessingVersion("insightface-five-point-v1")
            )
        }
    }

    func testSimilarityTransformMapsKnownPoints() throws {
        let source = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        let destination = [CGPoint(x: 5, y: 7), CGPoint(x: 25, y: 7), CGPoint(x: 5, y: 27)]
        let transform = try FaceImagePreprocessor.similarityTransform(from: source, to: destination)

        for (input, expected) in zip(source, destination) {
            let actual = input.applying(transform)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.001)
        }
    }

    func testSideEnrollmentRequiresRequestedYaw() {
        var gate = FaceCaptureGate(policy: .enrollment(.right))
        XCTAssertEqual(
            gate.evaluate(faces: [qualityFace(yaw: 0)], at: 0).state,
            .rejected(.wrongPose(.right))
        )

        let face = qualityFace(yaw: -0.5)
        var states: [FaceCaptureState] = []
        for time in stride(from: 0.0, through: 0.8, by: 0.2) {
            states.append(gate.evaluate(faces: [face], at: time).state)
        }
        XCTAssertEqual(states.last, .accepted, String(describing: states))
    }

    func testCooldownDoesNotAllowFaceDepartureReset() {
        XCTAssertFalse(RecognitionState.cooldown(until: Date()).allowsFaceDepartureReset)
        XCTAssertTrue(RecognitionState.scanning(matches: 0, samples: 0).allowsFaceDepartureReset)
        XCTAssertTrue(RecognitionState.processing.allowsFaceDepartureReset)
    }

    func testStandardPolicyDoesNotUseDevelopmentThreshold() {
        XCTAssertGreaterThan(RecognitionPolicy.standard.similarityThreshold, 0.40)
        XCTAssertGreaterThan(RecognitionPolicy.standard.cooldownDuration, 3)
    }

    func testForwardEnrollmentStillRejectsStrongTurn() {
        var gate = FaceCaptureGate(policy: .enrollment(.forward))
        XCTAssertEqual(
            gate.evaluate(faces: [qualityFace(yaw: 0.5)], at: 0).state,
            .rejected(.wrongPose(.forward))
        )
    }

    func testForwardEnrollmentAcceptsMissingOptionalPoseAxes() {
        var gate = FaceCaptureGate(policy: .enrollment(.forward))
        let face = qualityFace(yaw: 0, roll: nil, pitch: nil)

        var finalState: FaceCaptureState = .searching
        for time in stride(from: 0.0, through: 0.8, by: 0.2) {
            finalState = gate.evaluate(faces: [face], at: time).state
        }
        XCTAssertEqual(finalState, .accepted)
    }

    func testForwardEnrollmentRejectsMissingYaw() {
        var gate = FaceCaptureGate(policy: .enrollment(.forward))
        XCTAssertEqual(
            gate.evaluate(faces: [qualityFace(yaw: nil)], at: 0).state,
            .rejected(.wrongPose(.forward))
        )
    }

    func testForwardEnrollmentAllowsLaptopCameraPitch() {
        var gate = FaceCaptureGate(policy: .enrollment(.forward))
        let face = qualityFace(yaw: 0, pitch: 20 * .pi / 180)
        XCTAssertEqual(
            gate.evaluate(faces: [face], at: 0).state,
            .holding(progress: 0)
        )
    }

    func testRecognitionCaptureImmediatelyAcceptsQualityApprovedFrame() {
        var gate = FaceCaptureGate(policy: .recognition)
        let face = qualityFace(yaw: 0)

        let accepted = gate.evaluate(faces: [face], at: 0)
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertNotNil(accepted.acceptedFace)
        XCTAssertNil(gate.evaluate(faces: [face], at: 0.1).acceptedFace)

        var lowQualityGate = FaceCaptureGate(policy: .recognition)
        let lowQualityFace = DetectedFace(
            boundingBox: face.boundingBox,
            confidence: face.confidence,
            roll: face.roll,
            yaw: face.yaw,
            pitch: face.pitch,
            captureQuality: 0.2,
            landmarkConfidence: face.landmarkConfidence,
            hasRequiredLandmarks: face.hasRequiredLandmarks,
            landmarks: face.landmarks
        )
        XCTAssertEqual(
            lowQualityGate.evaluate(faces: [lowQualityFace], at: 0).state,
            .rejected(.lowQuality)
        )
    }

    private func axisEmbedding(_ index: Int) throws -> FaceEmbedding {
        var values = [Float](repeating: 0, count: 512)
        values[index] = 1
        return try FaceEmbedding(values: values)
    }

    private func result(_ matches: Bool) -> MatchResult {
        MatchResult(score: matches ? 0.8 : 0.1, isMatch: matches)
    }

    private func qualityFace(
        yaw: Double?,
        roll: Double? = 0,
        pitch: Double? = 0
    ) -> DetectedFace {
        DetectedFace(
            boundingBox: CGRect(x: 0.35, y: 0.30, width: 0.30, height: 0.40),
            confidence: 0.99,
            roll: roll,
            yaw: yaw,
            pitch: pitch,
            captureQuality: 0.9,
            landmarkConfidence: 0.9,
            hasRequiredLandmarks: true,
            landmarks: nil
        )
    }

    private func testPolicy() -> RecognitionPolicy {
        RecognitionPolicy(
            similarityThreshold: 0.40,
            requiredMatches: 3,
            windowCapacity: 4,
            windowDuration: 2,
            failureLimit: 5,
            cooldownDuration: 3,
            minimumSampleInterval: 0.35,
            faceDepartureDelay: 0.5
        )
    }
}
