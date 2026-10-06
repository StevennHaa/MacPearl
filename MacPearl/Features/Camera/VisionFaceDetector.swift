//
//  VisionFaceDetector.swift
//  MacPearl
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

struct DetectedFace: Equatable, Sendable {
    /// Vision-normalized coordinates with the origin at the lower-left.
    let boundingBox: CGRect
    let confidence: Float
    let roll: Double?
    let yaw: Double?
    let pitch: Double?
    let captureQuality: Float?
    let landmarkConfidence: Float?
    let hasRequiredLandmarks: Bool
    let landmarks: FaceLandmarks?
}

struct FaceDetectionResult: Equatable, Sendable {
    let faces: [DetectedFace]
    let errorDescription: String?

    static let empty = FaceDetectionResult(faces: [], errorDescription: nil)
}

/// Used only from CameraSessionController's serial sample queue.
final class VisionFaceDetector: @unchecked Sendable {
    private let rectangleRequest = VNDetectFaceRectanglesRequest()
    private let landmarkRequest = VNDetectFaceLandmarksRequest()
    private let qualityRequest = VNDetectFaceCaptureQualityRequest()

    init() {
        landmarkRequest.constellation = .constellation76Points
        qualityRequest.revision = VNDetectFaceCaptureQualityRequestRevision3
    }

    func detectFaces(
        in sampleBuffer: CMSampleBuffer,
        includeCaptureDetails: Bool = true
    ) throws -> [DetectedFace] {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw FaceDetectorError.missingPixelBuffer
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([rectangleRequest])

        let observations = rectangleRequest.results ?? []
        guard includeCaptureDetails,
              observations.count == 1,
              let observation = observations.first else {
            return observations.map(Self.basicFace)
        }

        landmarkRequest.inputFaceObservations = [observation]
        qualityRequest.inputFaceObservations = [observation]
        try handler.perform([landmarkRequest, qualityRequest])

        let landmarkObservation = landmarkRequest.results?.first
        let qualityObservation = qualityRequest.results?.first
        let landmarks = landmarkObservation?.landmarks
        let alignedLandmarks = landmarks.flatMap {
            Self.faceLandmarks(from: $0, in: observation.boundingBox)
        }

        return [
            DetectedFace(
                boundingBox: observation.boundingBox,
                confidence: observation.confidence,
                roll: observation.roll?.doubleValue,
                yaw: observation.yaw?.doubleValue,
                pitch: observation.pitch?.doubleValue,
                captureQuality: qualityObservation?.faceCaptureQuality,
                landmarkConfidence: landmarks?.confidence,
                hasRequiredLandmarks: alignedLandmarks != nil,
                landmarks: alignedLandmarks
            )
        ]
    }

    nonisolated private static func basicFace(_ observation: VNFaceObservation) -> DetectedFace {
        DetectedFace(
            boundingBox: observation.boundingBox,
            confidence: observation.confidence,
            roll: observation.roll?.doubleValue,
            yaw: observation.yaw?.doubleValue,
            pitch: observation.pitch?.doubleValue,
            captureQuality: nil,
            landmarkConfidence: nil,
            hasRequiredLandmarks: false,
            landmarks: nil
        )
    }

    nonisolated private static func faceLandmarks(
        from landmarks: VNFaceLandmarks2D,
        in boundingBox: CGRect
    ) -> FaceLandmarks? {
        guard let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let nose = landmarks.nose,
              let outerLips = landmarks.outerLips else { return nil }

        let leftEyePoints = points(leftEye, in: boundingBox)
        let rightEyePoints = points(rightEye, in: boundingBox)
        let nosePoints = points(nose, in: boundingBox)
        let mouthPoints = points(outerLips, in: boundingBox)
        guard !leftEyePoints.isEmpty, !rightEyePoints.isEmpty,
              let noseTip = nosePoints.min(by: { $0.y < $1.y }),
              let leftMouth = mouthPoints.min(by: { $0.x < $1.x }),
              let rightMouth = mouthPoints.max(by: { $0.x < $1.x }) else { return nil }

        let eyeCenters = [center(of: leftEyePoints), center(of: rightEyePoints)]
            .sorted { $0.x < $1.x }

        return FaceLandmarks(
            leftEye: eyeCenters[0],
            rightEye: eyeCenters[1],
            noseTip: noseTip,
            leftMouth: leftMouth,
            rightMouth: rightMouth
        )
    }

    nonisolated private static func points(
        _ region: VNFaceLandmarkRegion2D,
        in boundingBox: CGRect
    ) -> [CGPoint] {
        region.normalizedPoints.map { point in
            CGPoint(
                x: boundingBox.minX + (CGFloat(point.x) * boundingBox.width),
                y: boundingBox.minY + (CGFloat(point.y) * boundingBox.height)
            )
        }
    }

    nonisolated private static func center(of points: [CGPoint]) -> CGPoint {
        let count = CGFloat(points.count)
        return CGPoint(
            x: points.reduce(0) { $0 + $1.x } / count,
            y: points.reduce(0) { $0 + $1.y } / count
        )
    }
}

private enum FaceDetectorError: LocalizedError {
    case missingPixelBuffer

    var errorDescription: String? {
        "The sampled camera frame did not contain an image buffer."
    }
}
