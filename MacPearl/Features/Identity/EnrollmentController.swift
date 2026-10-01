//
//  EnrollmentController.swift
//  MacPearl
//

import Combine
import CoreGraphics
import Foundation

struct UserFaceTemplate: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let model: FaceEmbeddingModelMetadata
    let embeddings: [FaceCapturePose: FaceEmbedding]
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

    private var model: (any FaceEmbeddingModel)?
    private var embeddings: [FaceCapturePose: FaceEmbedding] = [:]
    private let templateStore: any FaceTemplateStoring

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
            model = try Self.loadModel()
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

        state = .processing(pose: pose, completed: completed)
        do {
            let faceImage = try frame.croppedFaceImage()
            embeddings[pose] = try model.embedding(for: faceImage)

            if let nextPose = FaceCapturePose.allCases.first(where: { embeddings[$0] == nil }) {
                state = .capturing(pose: nextPose, completed: embeddings.count)
                camera.captureEnrollmentPose(nextPose)
            } else {
                let template = UserFaceTemplate(
                    id: UUID(),
                    createdAt: Date(),
                    model: model.metadata,
                    embeddings: embeddings
                )
                try templateStore.save(template)
                state = .enrolled(template)
                camera.finishEnrollmentCapture()
            }
        } catch {
            state = .failed(error.localizedDescription)
            camera.finishEnrollmentCapture()
        }
    }

    func cancel(using camera: CameraSessionController) {
        embeddings.removeAll()
        state = .idle
        camera.retakeFace()
    }

    private func restoreTemplate() {
        do {
            if let template = try templateStore.load() {
                state = .enrolled(template)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func loadModel() throws -> CoreMLFaceEmbeddingModel {
        guard let modelURL = Bundle.main.url(
            forResource: "InsightFaceMobileFaceNet",
            withExtension: "mlmodelc"
        ) else {
            throw EnrollmentError.missingModel
        }

        return try CoreMLFaceEmbeddingModel(
            compiledModelURL: modelURL,
            metadata: FaceEmbeddingModelMetadata(
                name: "InsightFace MobileFaceNet",
                version: "buffalo_s v0.7 / w600k_mbf",
                license: "Non-commercial research only",
                source: URL(string: "https://github.com/deepinsight/insightface")!
            )
        )
    }
}

private extension CapturedFaceFrame {
    func croppedFaceImage(padding: CGFloat = 0.30) throws -> CGImage {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let box = face.boundingBox
        let side = max(box.width * imageWidth, box.height * imageHeight) * (1 + padding)
        let centerX = box.midX * imageWidth
        let centerY = (1 - box.midY) * imageHeight
        let cropRect = CGRect(
            x: centerX - (side / 2),
            y: centerY - (side / 2),
            width: side,
            height: side
        ).integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        guard !cropRect.isEmpty, let cropped = image.cropping(to: cropRect) else {
            throw EnrollmentError.invalidFaceCrop
        }
        return cropped
    }
}

private enum EnrollmentError: LocalizedError {
    case missingModel
    case invalidFaceCrop

    var errorDescription: String? {
        switch self {
        case .missingModel: "The face embedding model is unavailable."
        case .invalidFaceCrop: "The accepted face could not be cropped for enrollment."
        }
    }
}
