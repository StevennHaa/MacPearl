//
//  FaceTemplateStore.swift
//  MacPearl
//

import Foundation
import Security

protocol FaceTemplateStoring: Sendable {
    func load() throws -> UserFaceTemplate?
    func save(_ template: UserFaceTemplate) throws
    func delete() throws
}

final class KeychainFaceTemplateStore: FaceTemplateStoring, @unchecked Sendable {
    private let service = "com.stevenha.MacPearl.face-template"
    private let account = "primary"
    private let codec = FaceTemplateCodec()

    func load() throws -> UserFaceTemplate? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FaceTemplateStoreError.keychain(status)
        }
        return try codec.decode(data)
    }

    func save(_ template: UserFaceTemplate) throws {
        let data = try codec.encode(template)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw FaceTemplateStoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw FaceTemplateStoreError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FaceTemplateStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct FaceTemplateCodec: Sendable {
    static let schemaVersion = 2
    static let embeddingDimension = 512

    func encode(_ template: UserFaceTemplate) throws -> Data {
        try validate(template)
        let stored = StoredFaceTemplate(
            schemaVersion: Self.schemaVersion,
            id: template.id,
            createdAt: template.createdAt,
            preprocessingVersion: template.preprocessingVersion,
            model: StoredModelMetadata(template.model),
            embeddings: Dictionary(
                uniqueKeysWithValues: template.embeddings.map { ($0.key.rawValue, $0.value.values) }
            )
        )
        return try JSONEncoder().encode(stored)
    }

    func decode(_ data: Data) throws -> UserFaceTemplate {
        let version: StoredSchemaVersion
        do {
            version = try JSONDecoder().decode(StoredSchemaVersion.self, from: data)
        } catch {
            throw FaceTemplateStoreError.corruptTemplate
        }
        guard version.schemaVersion == Self.schemaVersion else {
            throw FaceTemplateStoreError.unsupportedVersion(version.schemaVersion)
        }

        let stored: StoredFaceTemplate
        do {
            stored = try JSONDecoder().decode(StoredFaceTemplate.self, from: data)
        } catch {
            throw FaceTemplateStoreError.corruptTemplate
        }

        do {
            let embeddings = try Dictionary(
                uniqueKeysWithValues: stored.embeddings.map { key, values in
                    guard let pose = FaceCapturePose(rawValue: key) else {
                        throw FaceTemplateStoreError.corruptTemplate
                    }
                    return (pose, try FaceEmbedding(values: values))
                }
            )
            let template = UserFaceTemplate(
                id: stored.id,
                createdAt: stored.createdAt,
                model: try stored.model.value(),
                preprocessingVersion: stored.preprocessingVersion,
                embeddings: embeddings
            )
            try validate(template)
            return template
        } catch let error as FaceTemplateStoreError {
            throw error
        } catch {
            throw FaceTemplateStoreError.corruptTemplate
        }
    }

    private func validate(_ template: UserFaceTemplate) throws {
        let expectedPoses = Set(FaceCapturePose.allCases)
        guard Set(template.embeddings.keys) == expectedPoses,
              template.embeddings.values.allSatisfy({ $0.values.count == Self.embeddingDimension }),
              !template.model.name.isEmpty,
              !template.model.version.isEmpty,
              !template.model.license.isEmpty else {
            throw FaceTemplateStoreError.corruptTemplate
        }
        guard template.preprocessingVersion == FaceImagePreprocessor.version else {
            throw FaceTemplateStoreError.incompatiblePreprocessingVersion(
                template.preprocessingVersion
            )
        }
    }
}

enum FaceTemplateStoreError: LocalizedError, Equatable {
    case corruptTemplate
    case unsupportedVersion(Int)
    case incompatiblePreprocessingVersion(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .corruptTemplate:
            "The stored face template is damaged and was not loaded."
        case .unsupportedVersion(let version):
            "The stored face template uses unsupported version \(version)."
        case .incompatiblePreprocessingVersion:
            "The stored face template uses older face preprocessing. Enroll again to continue."
        case .keychain(let status):
            "The face template could not be accessed securely (Keychain error \(status))."
        }
    }
}

private struct StoredSchemaVersion: Codable {
    let schemaVersion: Int
}

private struct StoredFaceTemplate: Codable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let preprocessingVersion: String
    let model: StoredModelMetadata
    let embeddings: [String: [Float]]
}

private struct StoredModelMetadata: Codable {
    let name: String
    let version: String
    let license: String
    let source: String

    init(_ metadata: FaceEmbeddingModelMetadata) {
        name = metadata.name
        version = metadata.version
        license = metadata.license
        source = metadata.source.absoluteString
    }

    func value() throws -> FaceEmbeddingModelMetadata {
        guard let sourceURL = URL(string: source) else {
            throw FaceTemplateStoreError.corruptTemplate
        }
        return FaceEmbeddingModelMetadata(
            name: name,
            version: version,
            license: license,
            source: sourceURL
        )
    }
}
