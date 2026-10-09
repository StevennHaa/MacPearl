import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct ProtectedCredentialEnvelope: Codable, Equatable, Sendable {
    let version: Int
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    static let currentVersion = 1
}

struct ProtectedCredentialCodec: Sendable {
    func seal(password: String, using keyData: Data) throws -> ProtectedCredentialEnvelope {
        guard keyData.count == 32 else {
            throw ProtectedCredentialError.invalidKey
        }
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(Data(password.utf8), using: key)
        return ProtectedCredentialEnvelope(
            version: ProtectedCredentialEnvelope.currentVersion,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    func open(_ envelope: ProtectedCredentialEnvelope, using keyData: Data) throws -> String {
        guard envelope.version == ProtectedCredentialEnvelope.currentVersion,
              keyData.count == 32,
              let nonce = try? AES.GCM.Nonce(data: envelope.nonce) else {
            throw ProtectedCredentialError.invalidEnvelope
        }
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        let plaintext = try AES.GCM.open(box, using: key)
        guard let password = String(data: plaintext, encoding: .utf8), !password.isEmpty else {
            throw ProtectedCredentialError.invalidEnvelope
        }
        return password
    }
}

enum ProtectedCredentialError: LocalizedError, Equatable {
    case invalidKey
    case invalidEnvelope
    case notConfigured
    case missingEncryptionKey
    case authorizationRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey: "The credential encryption key is invalid."
        case .invalidEnvelope: "The stored credential could not be decrypted."
        case .notConfigured: "Automatic unlock is not configured."
        case .missingEncryptionKey:
            "The protected encryption key is missing. Remove the stored password and set it up again while signed in."
        case .authorizationRequired: "Authorize MacPearl while signed in before locking."
        case .keychain(let status): "The protected credential could not be accessed (Keychain error \(status))."
        }
    }
}

protocol ProtectedCredentialStoring: Sendable {
    func hasStoredCredential() throws -> Bool
    func save(password: String) throws
    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial
    func delete() throws
}

struct ProtectedCredentialMaterial: Sendable {
    let envelopeData: Data
    let keyData: Data
}

final class KeychainProtectedCredentialStore: ProtectedCredentialStoring, @unchecked Sendable {
    private let service = "com.stevenha.MacPearl.unlock-credential"
    private let account = "primary"
    private let keyAccount = "encryption-key"
    private let codec = ProtectedCredentialCodec()

    func hasStoredCredential() throws -> Bool {
        try hasItem(account: account) && hasItem(account: keyAccount)
    }

    func save(password: String) throws {
        guard !password.isEmpty else { throw ProtectedCredentialError.invalidEnvelope }
        let keyData = try randomKey()
        let envelope = try codec.seal(password: password, using: keyData)
        let envelopeData = try JSONEncoder().encode(envelope)
        try replace(query: baseQuery(account: account), value: envelopeData)

        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            throw ProtectedCredentialError.keychain(errSecParam)
        }
        var item = baseQuery(account: keyAccount)
        item[kSecValueData as String] = keyData
        item[kSecAttrAccessControl as String] = access
        let keyStatus = SecItemAdd(item as CFDictionary, nil)
        if keyStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: keyAccount) as CFDictionary,
                [kSecValueData as String: keyData] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw ProtectedCredentialError.keychain(updateStatus)
            }
        } else if keyStatus != errSecSuccess {
            throw ProtectedCredentialError.keychain(keyStatus)
        }
    }

    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial {
        var envelopeQuery = baseQuery(account: account)
        envelopeQuery[kSecReturnData as String] = true
        var envelopeResult: CFTypeRef?
        let envelopeStatus = SecItemCopyMatching(envelopeQuery as CFDictionary, &envelopeResult)
        guard envelopeStatus == errSecSuccess, let envelopeData = envelopeResult as? Data else {
            throw envelopeStatus == errSecItemNotFound
                ? ProtectedCredentialError.notConfigured
                : ProtectedCredentialError.keychain(envelopeStatus)
        }

        var keyQuery = baseQuery(account: keyAccount)
        keyQuery[kSecReturnData as String] = true
        let context = LAContext()
        context.localizedReason = "Authorize MacPearl to prepare automatic unlock"
        keyQuery[kSecUseAuthenticationContext as String] = context
        var keyResult: CFTypeRef?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyResult)
        guard keyStatus == errSecSuccess, let keyData = keyResult as? Data else {
            if keyStatus == errSecUserCanceled {
                throw ProtectedCredentialError.authorizationRequired
            }
            if keyStatus == errSecItemNotFound {
                throw ProtectedCredentialError.missingEncryptionKey
            }
            throw ProtectedCredentialError.keychain(keyStatus)
        }
        return ProtectedCredentialMaterial(envelopeData: envelopeData, keyData: keyData)
    }

    func delete() throws {
        for account in [account, keyAccount] {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ProtectedCredentialError.keychain(status)
            }
        }
    }

    private func replace(query: [String: Any], value: Data) throws {
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ProtectedCredentialError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw ProtectedCredentialError.keychain(updateStatus)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func hasItem(account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProtectedCredentialError.keychain(status)
        }
        return status == errSecSuccess
    }

    private func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ProtectedCredentialError.keychain(status) }
        return Data(bytes)
    }
}

enum ProtectedCredentialStatus: Equatable, Sendable {
    case unavailable
    case configured
    case sessionReady
    case failed(String)

    var message: String {
        switch self {
        case .unavailable: "Automatic unlock is not configured"
        case .configured: "Credential stored; authorize before locking"
        case .sessionReady: "Automatic unlock session is armed until disarmed or MacPearl quits"
        case .failed(let message): message
        }
    }
}

@MainActor
final class ProtectedCredentialController: ObservableObject {
    @Published private(set) var status: ProtectedCredentialStatus = .unavailable

    private let store: any ProtectedCredentialStoring
    private let codec = ProtectedCredentialCodec()
    // Like Glance, keep the user-authorized session key—not the plaintext
    // password—in memory so the lock-screen path needs no Keychain prompt.
    private var cachedMaterial: ProtectedCredentialMaterial?

    init(store: (any ProtectedCredentialStoring)? = nil) {
        self.store = store ?? KeychainProtectedCredentialStore()
        do {
            status = try self.store.hasStoredCredential() ? .configured : .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    var isConfigured: Bool {
        if case .unavailable = status { return false }
        if case .failed = status { return false }
        return true
    }

    func save(password: String) {
        do {
            try store.save(password: password)
            status = .configured
            prepareSession()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func prepareSession() {
        do {
            cachedMaterial = try store.loadAuthorizedMaterial()
            status = .sessionReady
        } catch {
            cachedMaterial = nil
            status = .failed(error.localizedDescription)
        }
    }

    func clearSession() {
        cachedMaterial = nil
        if isConfigured { status = .configured }
    }

    func delete() {
        do {
            try store.delete()
            clearSession()
            status = .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func withCachedPassword<T>(_ body: (String) -> T) -> T? {
        guard let cachedMaterial else { return nil }
        do {
            let envelope = try JSONDecoder().decode(
                ProtectedCredentialEnvelope.self,
                from: cachedMaterial.envelopeData
            )
            return body(try codec.open(envelope, using: cachedMaterial.keyData))
        } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
    }
}
