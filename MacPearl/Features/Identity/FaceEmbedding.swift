//
//  FaceEmbedding.swift
//  MacPearl
//

import Foundation

struct FaceEmbedding: Equatable, Sendable {
    let values: [Float]

    init(values: [Float]) throws {
        guard !values.isEmpty else { throw FaceEmbeddingError.emptyVector }
        guard values.allSatisfy(\.isFinite) else { throw FaceEmbeddingError.nonFiniteValue }

        let magnitude = sqrt(values.reduce(Float.zero) { $0 + ($1 * $1) })
        guard magnitude > .ulpOfOne else { throw FaceEmbeddingError.zeroMagnitude }
        self.values = values.map { $0 / magnitude }
    }

    func cosineSimilarity(to other: FaceEmbedding) throws -> Float {
        guard values.count == other.values.count else {
            throw FaceEmbeddingError.dimensionMismatch(values.count, other.values.count)
        }
        return zip(values, other.values).reduce(Float.zero) { $0 + ($1.0 * $1.1) }
    }
}

enum FaceEmbeddingError: LocalizedError {
    case emptyVector
    case nonFiniteValue
    case zeroMagnitude
    case dimensionMismatch(Int, Int)

    var errorDescription: String? {
        switch self {
        case .emptyVector:
            "The model returned an empty embedding."
        case .nonFiniteValue:
            "The model returned a non-finite embedding value."
        case .zeroMagnitude:
            "The model returned an embedding with zero magnitude."
        case .dimensionMismatch(let first, let second):
            "Embedding dimensions do not match (\(first) and \(second))."
        }
    }
}
