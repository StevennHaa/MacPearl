//
//  CoreMLFaceEmbeddingModel.swift
//  MacPearl
//

import CoreGraphics
import CoreML
import Foundation
import Vision

struct FaceEmbeddingModelMetadata: Equatable, Sendable {
    let name: String
    let version: String
    let license: String
    let source: URL
}

protocol FaceEmbeddingModel: Sendable {
    var metadata: FaceEmbeddingModelMetadata { get }
    var onDiskSize: Int64 { get }

    func embedding(for image: CGImage) throws -> FaceEmbedding
}

final class CoreMLFaceEmbeddingModel: FaceEmbeddingModel, @unchecked Sendable {
    let metadata: FaceEmbeddingModelMetadata
    let onDiskSize: Int64

    private let visionModel: VNCoreMLModel
    private let cropAndScaleOption: VNImageCropAndScaleOption

    init(
        compiledModelURL: URL,
        metadata: FaceEmbeddingModelMetadata,
        cropAndScaleOption: VNImageCropAndScaleOption = .scaleFill,
        computeUnits: MLComputeUnits = .all
    ) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)

        self.metadata = metadata
        self.onDiskSize = try Self.directorySize(at: compiledModelURL)
        self.visionModel = try VNCoreMLModel(for: model)
        self.cropAndScaleOption = cropAndScaleOption
    }

    func embedding(for image: CGImage) throws -> FaceEmbedding {
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = cropAndScaleOption

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        guard let observations = request.results as? [VNCoreMLFeatureValueObservation],
            let multiArray = observations.compactMap(\.featureValue.multiArrayValue).first else {
            throw CoreMLFaceEmbeddingError.missingMultiArrayOutput
        }

        let values = (0..<multiArray.count).map { multiArray[$0].floatValue }
        return try FaceEmbedding(values: values)
    }

    private static func directorySize(at url: URL) throws -> Int64 {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard resourceValues.isDirectory == true else {
            return Int64(resourceValues.fileSize ?? 0)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw CoreMLFaceEmbeddingError.cannotMeasureModel
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

private enum CoreMLFaceEmbeddingError: LocalizedError {
    case missingMultiArrayOutput
    case cannotMeasureModel

    var errorDescription: String? {
        switch self {
        case .missingMultiArrayOutput:
            "The Core ML model did not return a numeric embedding output."
        case .cannotMeasureModel:
            "The Core ML model size could not be measured."
        }
    }
}
