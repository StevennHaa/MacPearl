//
//  FaceMatcher.swift
//  MacPearl
//

import Foundation

struct RecognitionPolicy: Equatable, Sendable {
    let similarityThreshold: Float
    let requiredMatches: Int
    let windowCapacity: Int
    let windowDuration: TimeInterval
    let failureLimit: Int
    let cooldownDuration: TimeInterval
    let minimumSampleInterval: TimeInterval
    let faceDepartureDelay: TimeInterval

    nonisolated static var standard: RecognitionPolicy { RecognitionPolicy(
        similarityThreshold: 0.55,
        requiredMatches: 3,
        windowCapacity: 4,
        windowDuration: 2,
        failureLimit: 5,
        cooldownDuration: 10,
        minimumSampleInterval: 0.18,
        faceDepartureDelay: 0.5
    ) }

#if DEBUG
    nonisolated static var development: RecognitionPolicy { RecognitionPolicy(
        similarityThreshold: 0.40,
        requiredMatches: 3,
        windowCapacity: 4,
        windowDuration: 2,
        failureLimit: 5,
        cooldownDuration: 3,
        // Keep samples temporally distinct while allowing a three-match decision
        // in well under a second on a 15 FPS analysis stream.
        minimumSampleInterval: 0.18,
        faceDepartureDelay: 0.5
    ) }
#endif
}

struct FaceTemplateMatcher: Sendable {
    let centroid: FaceEmbedding
    let threshold: Float

    init(template: UserFaceTemplate, threshold: Float) throws {
        guard template.preprocessingVersion == FaceImagePreprocessor.version,
              template.model == FaceEmbeddingModelProvider.metadata else {
            throw RecognitionError.incompatibleTemplate
        }
        let ordered = try FaceCapturePose.allCases.map { pose in
            guard let embedding = template.embeddings[pose] else {
                throw RecognitionError.incompleteTemplate
            }
            return embedding
        }
        let dimension = ordered[0].values.count
        guard ordered.allSatisfy({ $0.values.count == dimension }) else {
            throw RecognitionError.incompleteTemplate
        }
        let mean = (0..<dimension).map { index in
            ordered.reduce(Float.zero) { $0 + $1.values[index] } / Float(ordered.count)
        }
        centroid = try FaceEmbedding(values: mean)
        self.threshold = threshold
    }

    func evaluate(_ liveEmbedding: FaceEmbedding) throws -> MatchResult {
        let score = try liveEmbedding.cosineSimilarity(to: centroid)
        return MatchResult(score: score, isMatch: score >= threshold)
    }
}

struct MatchResult: Equatable, Sendable {
    let score: Float
    let isMatch: Bool
}

struct MatchObservation: Equatable, Sendable {
    let result: MatchResult
    let timestamp: Date
}

enum StabilityDecision: Equatable, Sendable {
    case pending(matches: Int, samples: Int)
    case matched
    case cooldown(until: Date)
}

struct MatchDecisionStabilizer: Sendable {
    private(set) var observations: [MatchObservation] = []
    private(set) var consecutiveFailures = 0
    let policy: RecognitionPolicy

    init(policy: RecognitionPolicy) {
        self.policy = policy
    }

    mutating func record(_ result: MatchResult, at date: Date) -> StabilityDecision {
        observations.removeAll { date.timeIntervalSince($0.timestamp) > policy.windowDuration }
        observations.append(MatchObservation(result: result, timestamp: date))
        if observations.count > policy.windowCapacity {
            observations.removeFirst(observations.count - policy.windowCapacity)
        }

        if result.isMatch {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }

        if consecutiveFailures >= policy.failureLimit {
            let until = date.addingTimeInterval(policy.cooldownDuration)
            reset()
            return .cooldown(until: until)
        }

        let matches = observations.count(where: { $0.result.isMatch })
        if matches >= policy.requiredMatches {
            return .matched
        }
        return .pending(matches: matches, samples: observations.count)
    }

    mutating func reset() {
        observations.removeAll(keepingCapacity: true)
        consecutiveFailures = 0
    }
}

enum RecognitionError: LocalizedError {
    case incompatibleTemplate
    case incompleteTemplate

    var errorDescription: String? {
        switch self {
        case .incompatibleTemplate:
            "The stored template uses an older face format. Enroll again to continue."
        case .incompleteTemplate:
            "The stored face template is incomplete. Enroll again to continue."
        }
    }
}
