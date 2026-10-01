//
//  EmbeddingModelEvaluator.swift
//  MacPearl
//

import CoreGraphics
import Foundation

struct LabeledFaceSample: Sendable {
    let identity: String
    let image: CGImage
}

struct EmbeddingScoreSummary: Equatable, Sendable {
    let count: Int
    let minimum: Float?
    let median: Float?
    let maximum: Float?
}

struct EmbeddingModelEvaluation: Equatable, Sendable {
    let metadata: FaceEmbeddingModelMetadata
    let onDiskSize: Int64
    let sampleCount: Int
    let medianLatencyMilliseconds: Double
    let percentile95LatencyMilliseconds: Double
    let samePersonScores: EmbeddingScoreSummary
    let differentPersonScores: EmbeddingScoreSummary

    /// Positive values indicate a clean gap on this particular held-out set.
    var observedSeparation: Float? {
        guard let lowestSame = samePersonScores.minimum,
            let highestDifferent = differentPersonScores.maximum else { return nil }
        return lowestSame - highestDifferent
    }
}

enum EmbeddingModelEvaluator {
    static func evaluate(
        model: any FaceEmbeddingModel,
        samples: [LabeledFaceSample],
        warmupCount: Int = 3
    ) throws -> EmbeddingModelEvaluation {
        guard samples.count >= 2 else { throw EmbeddingEvaluationError.insufficientSamples }
        guard Set(samples.map(\.identity)).count >= 2 else {
            throw EmbeddingEvaluationError.insufficientIdentities
        }
        guard Dictionary(grouping: samples, by: \.identity).values.contains(where: { $0.count >= 2 }) else {
            throw EmbeddingEvaluationError.missingSamePersonPair
        }

        if let first = samples.first {
            for _ in 0..<max(0, warmupCount) {
                _ = try model.embedding(for: first.image)
            }
        }

        var embeddings: [FaceEmbedding] = []
        var latencies: [Double] = []
        for sample in samples {
            let start = ContinuousClock.now
            embeddings.append(try model.embedding(for: sample.image))
            let elapsed = start.duration(to: .now)
            latencies.append(Self.milliseconds(elapsed))
        }

        var samePerson: [Float] = []
        var differentPerson: [Float] = []
        for firstIndex in samples.indices {
            for secondIndex in samples.indices where secondIndex > firstIndex {
                let score = try embeddings[firstIndex].cosineSimilarity(to: embeddings[secondIndex])
                if samples[firstIndex].identity == samples[secondIndex].identity {
                    samePerson.append(score)
                } else {
                    differentPerson.append(score)
                }
            }
        }

        return EmbeddingModelEvaluation(
            metadata: model.metadata,
            onDiskSize: model.onDiskSize,
            sampleCount: samples.count,
            medianLatencyMilliseconds: percentile(latencies, fraction: 0.50) ?? 0,
            percentile95LatencyMilliseconds: percentile(latencies, fraction: 0.95) ?? 0,
            samePersonScores: scoreSummary(samePerson),
            differentPersonScores: scoreSummary(differentPerson)
        )
    }

    private static func scoreSummary(_ values: [Float]) -> EmbeddingScoreSummary {
        EmbeddingScoreSummary(
            count: values.count,
            minimum: values.min(),
            median: percentile(values, fraction: 0.50),
            maximum: values.max()
        )
    }

    private static func percentile<T: BinaryFloatingPoint>(
        _ values: [T],
        fraction: Double
    ) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}

private enum EmbeddingEvaluationError: LocalizedError {
    case insufficientSamples
    case insufficientIdentities
    case missingSamePersonPair

    var errorDescription: String? {
        switch self {
        case .insufficientSamples:
            "At least two face samples are required."
        case .insufficientIdentities:
            "At least two different identities are required."
        case .missingSamePersonPair:
            "At least one identity needs two samples for a same-person comparison."
        }
    }
}
