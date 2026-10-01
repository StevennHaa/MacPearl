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

    func detectFaces(in sampleBuffer: CMSampleBuffer) throws -> [DetectedFace] {
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
        guard observations.count == 1, let observation = observations.first else {
            return observations.map(Self.basicFace)
        }

        landmarkRequest.inputFaceObservations = [observation]
        qualityRequest.inputFaceObservations = [observation]
        try handler.perform([landmarkRequest, qualityRequest])

        let landmarkObservation = landmarkRequest.results?.first
        let qualityObservation = qualityRequest.results?.first
        let landmarks = landmarkObservation?.landmarks

        return [
            DetectedFace(
                boundingBox: observation.boundingBox,
                confidence: observation.confidence,
                roll: observation.roll?.doubleValue,
                yaw: observation.yaw?.doubleValue,
                pitch: observation.pitch?.doubleValue,
                captureQuality: qualityObservation?.faceCaptureQuality,
                landmarkConfidence: landmarks?.confidence,
                hasRequiredLandmarks: landmarks?.leftEye != nil
                    && landmarks?.rightEye != nil
                    && landmarks?.nose != nil
                    && landmarks?.outerLips != nil
            )
        ]
    }

    private static func basicFace(_ observation: VNFaceObservation) -> DetectedFace {
        DetectedFace(
            boundingBox: observation.boundingBox,
            confidence: observation.confidence,
            roll: observation.roll?.doubleValue,
            yaw: observation.yaw?.doubleValue,
            pitch: observation.pitch?.doubleValue,
            captureQuality: nil,
            landmarkConfidence: nil,
            hasRequiredLandmarks: false
        )
    }
}

private enum FaceDetectorError: LocalizedError {
    case missingPixelBuffer

    var errorDescription: String? {
        "The sampled camera frame did not contain an image buffer."
    }
}
