//
//  FaceImagePreprocessor.swift
//  MacPearl
//

import CoreGraphics
import CoreImage
import Foundation

struct FaceLandmarks: Equatable, Sendable {
    /// Vision-normalized image coordinates with the origin at the lower-left.
    let leftEye: CGPoint
    let rightEye: CGPoint
    let noseTip: CGPoint
    let leftMouth: CGPoint
    let rightMouth: CGPoint
}

enum FaceImagePreprocessor {
    nonisolated static let version = "insightface-five-point-illumination-v3"
    nonisolated static let outputSize = CGSize(width: 112, height: 112)
    nonisolated static let targetLuminance: CGFloat = 0.50
    nonisolated static let maximumExposureAdjustment: Float = 2.0
    nonisolated private static let sRGBColorSpace = CGColorSpace(
        name: CGColorSpace.sRGB
    )!
    nonisolated private static let renderContext = CIContext(
        options: [.cacheIntermediates: false]
    )

    nonisolated private static let destinationPoints = [
        CGPoint(x: 38.2946, y: 112 - 51.6963),
        CGPoint(x: 73.5318, y: 112 - 51.5014),
        CGPoint(x: 56.0252, y: 112 - 71.7366),
        CGPoint(x: 41.5493, y: 112 - 92.3655),
        CGPoint(x: 70.7299, y: 112 - 92.2041)
    ]

    nonisolated static func alignedImage(from frame: CapturedFaceFrame) throws -> CGImage {
        guard let landmarks = frame.face.landmarks else {
            throw FaceImagePreprocessorError.missingLandmarks
        }

        let width = CGFloat(frame.image.width)
        let height = CGFloat(frame.image.height)
        let sourcePoints = [
            landmarks.leftEye,
            landmarks.rightEye,
            landmarks.noseTip,
            landmarks.leftMouth,
            landmarks.rightMouth
        ].map { CGPoint(x: $0.x * width, y: $0.y * height) }

        let transform = try similarityTransform(from: sourcePoints, to: destinationPoints)
        let input = CIImage(cgImage: frame.image)
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let aligned = input.transformed(by: transform).cropped(to: outputRect)
        let normalized = try normalizeIllumination(in: aligned)
        guard let image = renderContext.createCGImage(
            normalized,
            from: outputRect,
            format: .RGBA8,
            colorSpace: sRGBColorSpace
        ) else {
            throw FaceImagePreprocessorError.cannotRenderAlignedFace
        }
        return image
    }

    /// Corrects only broad exposure differences after five-point alignment. The
    /// bounded adjustment avoids amplifying very dark frames into noisy inputs.
    nonisolated static func normalizeIllumination(in image: CIImage) throws -> CIImage {
        let sampleRect = CGRect(x: 24, y: 18, width: 64, height: 76)
            .intersection(image.extent)
        guard !sampleRect.isEmpty,
              let averageFilter = CIFilter(
                name: "CIAreaAverage",
                parameters: [
                    kCIInputImageKey: image,
                    kCIInputExtentKey: CIVector(cgRect: sampleRect)
                ]
              ),
              let averageImage = averageFilter.outputImage else {
            throw FaceImagePreprocessorError.cannotNormalizeIllumination
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        renderContext.render(
            averageImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: sRGBColorSpace
        )

        let red = linearComponent(fromSRGB: CGFloat(pixel[0]) / 255)
        let green = linearComponent(fromSRGB: CGFloat(pixel[1]) / 255)
        let blue = linearComponent(fromSRGB: CGFloat(pixel[2]) / 255)
        let linearLuminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        let exposure = exposureAdjustment(forLinearLuminance: linearLuminance)
        return image.applyingFilter(
            "CIExposureAdjust",
            parameters: [kCIInputEVKey: exposure]
        )
    }

    nonisolated static func exposureAdjustment(forLuminance luminance: CGFloat) -> Float {
        exposureAdjustment(forLinearLuminance: linearComponent(fromSRGB: luminance))
    }

    nonisolated private static func exposureAdjustment(
        forLinearLuminance luminance: CGFloat
    ) -> Float {
        guard luminance.isFinite, luminance > .ulpOfOne else {
            return maximumExposureAdjustment
        }
        let linearTarget = linearComponent(fromSRGB: targetLuminance)
        let adjustment = Float(log2(linearTarget / luminance))
        return min(max(adjustment, -maximumExposureAdjustment), maximumExposureAdjustment)
    }

    nonisolated private static func linearComponent(fromSRGB component: CGFloat) -> CGFloat {
        let clamped = min(max(component, 0), 1)
        if clamped <= 0.04045 {
            return clamped / 12.92
        }
        return pow((clamped + 0.055) / 1.055, 2.4)
    }

    /// Least-squares similarity transform: x' = ax - by + tx, y' = bx + ay + ty.
    nonisolated static func similarityTransform(
        from source: [CGPoint],
        to destination: [CGPoint]
    ) throws -> CGAffineTransform {
        guard source.count == destination.count, source.count >= 2 else {
            throw FaceImagePreprocessorError.invalidLandmarkGeometry
        }

        let count = CGFloat(source.count)
        let sourceCenter = CGPoint(
            x: source.reduce(0) { $0 + $1.x } / count,
            y: source.reduce(0) { $0 + $1.y } / count
        )
        let destinationCenter = CGPoint(
            x: destination.reduce(0) { $0 + $1.x } / count,
            y: destination.reduce(0) { $0 + $1.y } / count
        )

        var denominator: CGFloat = 0
        var real: CGFloat = 0
        var imaginary: CGFloat = 0
        for (sourcePoint, destinationPoint) in zip(source, destination) {
            let sx = sourcePoint.x - sourceCenter.x
            let sy = sourcePoint.y - sourceCenter.y
            let dx = destinationPoint.x - destinationCenter.x
            let dy = destinationPoint.y - destinationCenter.y
            denominator += (sx * sx) + (sy * sy)
            real += (sx * dx) + (sy * dy)
            imaginary += (sx * dy) - (sy * dx)
        }

        guard denominator > .ulpOfOne else {
            throw FaceImagePreprocessorError.invalidLandmarkGeometry
        }
        let a = real / denominator
        let b = imaginary / denominator
        let tx = destinationCenter.x - (a * sourceCenter.x) + (b * sourceCenter.y)
        let ty = destinationCenter.y - (b * sourceCenter.x) - (a * sourceCenter.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }
}

enum FaceImagePreprocessorError: LocalizedError {
    case missingLandmarks
    case invalidLandmarkGeometry
    case cannotNormalizeIllumination
    case cannotRenderAlignedFace

    var errorDescription: String? {
        switch self {
        case .missingLandmarks:
            "The accepted face is missing landmarks required for recognition."
        case .invalidLandmarkGeometry:
            "The detected face landmarks could not be aligned."
        case .cannotNormalizeIllumination:
            "The aligned face lighting could not be normalized."
        case .cannotRenderAlignedFace:
            "The aligned face image could not be created."
        }
    }
}
