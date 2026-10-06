//
//  FaceEmbeddingModelProvider.swift
//  MacPearl
//

import Foundation

enum FaceEmbeddingModelProvider {
    static let metadata = FaceEmbeddingModelMetadata(
        name: "InsightFace MobileFaceNet",
        version: "buffalo_s v0.7 / w600k_mbf",
        license: "Non-commercial research only",
        source: URL(string: "https://github.com/deepinsight/insightface")!
    )

    private static let sharedModel: Result<CoreMLFaceEmbeddingModel, Error> = Result {
        guard let modelURL = Bundle.main.url(
            forResource: "InsightFaceMobileFaceNet",
            withExtension: "mlmodelc"
        ) else {
            throw FaceEmbeddingModelProviderError.missingModel
        }
        return try CoreMLFaceEmbeddingModel(compiledModelURL: modelURL, metadata: metadata)
    }

    static func load() throws -> CoreMLFaceEmbeddingModel {
        try sharedModel.get()
    }
}

enum FaceEmbeddingModelProviderError: LocalizedError {
    case missingModel

    var errorDescription: String? {
        "The face embedding model is unavailable."
    }
}
