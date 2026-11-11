//
//  EnrollmentController.swift
//  MacPearl
//

import Combine
import Foundation

struct UserFaceTemplate: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let model: FaceEmbeddingModelMetadata
    let preprocessingVersion: String
    let embeddings: [FaceCapturePose: FaceEmbedding]

    var isCompatibleWithCurrentModel: Bool {
        preprocessingVersion == FaceImagePreprocessor.version && model == FaceEmbeddingModelProvider.metadata
    }
}

enum EnrollmentState: Equatable, Sendable {
    case idle
    case capturing(pose: FaceCapturePose, completed: Int)
    case processing(pose: FaceCapturePose, completed: Int)
    case enrolled(UserFaceTemplate)
    case failed(String)
}

@MainActor
final class EnrollmentController: ObservableObject {
    @Published private(set) var state: EnrollmentState = .idle
    @Published private(set) var requiresReenrollment = false

    private var model: (any FaceEmbeddingModel)?
    private var embeddings: [FaceCapturePose: FaceEmbedding] = [:]
    private let templateStore: any FaceTemplateStoring
    private var enrollmentID = UUID()

    init(templateStore: (any FaceTemplateStoring)? = nil) {
        self.templateStore = templateStore ?? KeychainFaceTemplateStore()
        restoreTemplate()
    }

    var template: UserFaceTemplate? {
        guard case .enrolled(let template) = state else { return nil }
        return template
    }

    var isActive: Bool {
        switch state {
        case .capturing, .processing: true
        default: false
        }
    }

    func begin(using camera: CameraSessionController) {
        do {
            enrollmentID = UUID()
            model = try FaceEmbeddingModelProvider.load()
            embeddings.removeAll(keepingCapacity: true)
            state = .capturing(pose: .forward, completed: 0)
            camera.captureEnrollmentPose(.forward)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func receive(_ frame: CapturedFaceFrame, using camera: CameraSessionController) {
        guard case .capturing(let pose, let completed) = state,
              let model else { return }

        let requestID = enrollmentID
        state = .processing(pose: pose, completed: completed)
        Task { [weak self] in
            do {
                let embedding = try await Task.detached(priority: .userInitiated) {
                    let faceImage = try FaceImagePreprocessor.alignedImage(from: frame)
                    return try model.embedding(for: faceImage)
                }.value
                guard let self, self.enrollmentID == requestID else { return }
                try self.accept(embedding, for: pose, using: camera)
            } catch {
                guard let self, self.enrollmentID == requestID else { return }
                self.state = .failed(error.localizedDescription)
                camera.finishFaceCapture()
            }
        }
    }

    func cancel(using camera: CameraSessionController) {
        enrollmentID = UUID()
        embeddings.removeAll()
        state = .idle
        camera.retakeFace()
    }

    func reloadTemplate() {
        enrollmentID = UUID()
        embeddings.removeAll()
        state = .idle
        restoreTemplate()
    }

    func deleteTemplate() throws {
        // Invalidate in-flight embedding tasks before touching persistent data.
        enrollmentID = UUID()
        embeddings.removeAll()
        model = nil
        state = .idle
        do {
            try templateStore.delete()
            requiresReenrollment = false
        } catch {
            state = .failed("The saved face could not be removed. Try again. \(error.localizedDescription)")
            throw error
        }
    }

    private func accept(
        _ embedding: FaceEmbedding,
        for pose: FaceCapturePose,
        using camera: CameraSessionController
    ) throws {
        embeddings[pose] = embedding
        if let nextPose = FaceCapturePose.allCases.first(where: { embeddings[$0] == nil }) {
            state = .capturing(pose: nextPose, completed: embeddings.count)
            camera.captureEnrollmentPose(nextPose)
            return
        }

        guard let model else { throw EnrollmentError.missingModel }
        let template = UserFaceTemplate(
            id: UUID(),
            createdAt: Date(),
            model: model.metadata,
            preprocessingVersion: FaceImagePreprocessor.version,
            embeddings: embeddings
        )
        try templateStore.save(template)
        requiresReenrollment = false
        state = .enrolled(template)
        camera.finishFaceCapture()
    }

    private func restoreTemplate() {
        requiresReenrollment = false
        do {
            if let template = try templateStore.load() {
                guard template.isCompatibleWithCurrentModel else {
                    throw RecognitionError.incompatibleTemplate
                }
                state = .enrolled(template)
            }
        } catch RecognitionError.incompatibleTemplate {
            requiresReenrollment = true
            state = .failed("The recognition model has changed. Enroll your face again before using automatic unlock.")
        } catch FaceTemplateStoreError.unsupportedVersion(1) {
            requiresReenrollment = true
            state = .failed("The stored template uses older face preprocessing. Enroll again to continue.")
        } catch FaceTemplateStoreError.incompatiblePreprocessingVersion {
            requiresReenrollment = true
            state = .failed("Lighting normalization has improved. Enroll again to update your face template.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private enum EnrollmentError: LocalizedError {
    case missingModel

    var errorDescription: String? {
        "The face embedding model is unavailable."
    }
}
