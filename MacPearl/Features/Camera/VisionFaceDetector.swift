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
}

struct FaceDetectionResult: Equatable, Sendable {
    let faces: [DetectedFace]
    let errorDescription: String?

    static let empty = FaceDetectionResult(faces: [], errorDescription: nil)
}

/// Used only from CameraSessionController's serial sample queue.
final class VisionFaceDetector: @unchecked Sendable {
    private let request = VNDetectFaceRectanglesRequest()

    func detectFaces(in sampleBuffer: CMSampleBuffer) throws -> [DetectedFace] {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw FaceDetectorError.missingPixelBuffer
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([request])

        return (request.results ?? []).map {
            DetectedFace(boundingBox: $0.boundingBox, confidence: $0.confidence)
        }
    }
}

private enum FaceDetectorError: LocalizedError {
    case missingPixelBuffer

    var errorDescription: String? {
        "The sampled camera frame did not contain an image buffer."
    }
}
