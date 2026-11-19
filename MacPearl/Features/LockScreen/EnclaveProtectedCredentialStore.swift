import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The free build stores only ciphertext and a device-wrapped Enclave key in
/// the file-based Keychain. User presence is enforced by the Enclave operation,
/// not by an app-level authentication check or a Data Protection Keychain item.
nonisolated struct EnclaveCredentialRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let wrappedPrivateKey: Data
    let peerPublicKey: Data
    let envelopeData: Data

    func validate() throws {
        guard version == Self.currentVersion, !wrappedPrivateKey.isEmpty,
              !peerPublicKey.isEmpty, !envelopeData.isEmpty else {
            throw ProtectedCredentialError.invalidEnvelope
        }
        _ = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        let envelope = try JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: envelopeData)
        guard envelope.version == ProtectedCredentialEnvelope.currentVersion,
              envelope.nonce.count == 12, envelope.tag.count == 16,
              !envelope.ciphertext.isEmpty else { throw ProtectedCredentialError.invalidEnvelope }
    }
}

nonisolated struct EnclaveCredentialKey: Sendable {
    let wrappedPrivateKey: Data
    let peerPublicKey: Data
    let keyData: Data
}

nonisolated protocol EnclaveKeyProtecting: Sendable {
    func create(context: LAContext) throws -> EnclaveCredentialKey
    func unlock(_ record: EnclaveCredentialRecord, context: LAContext) throws -> Data
}

nonisolated struct SecureEnclaveKeyProtector: EnclaveKeyProtecting {
    private static let domain = Data("com.stevenha.MacPearl.credential-enclave.v1".utf8)

    func create(context: LAContext) throws -> EnclaveCredentialKey {
        guard SecureEnclave.isAvailable else { throw ProtectedCredentialError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &error) else {
            throw ProtectedCredentialError.keychain(errSecParam)
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access,
                                                                 authenticationContext: context)
        // Only this public point is retained; the software peer's private key is
        // discarded. The shared secret can subsequently be recovered only by
        // the protected Enclave private-key operation on this device.
        let peer = P256.KeyAgreement.PrivateKey().publicKey
        let secret = try key.sharedSecretFromKeyAgreement(with: peer)
        return EnclaveCredentialKey(wrappedPrivateKey: key.dataRepresentation,
            peerPublicKey: peer.x963Representation, keyData: Self.derive(secret))
    }

    func unlock(_ record: EnclaveCredentialRecord, context: LAContext) throws -> Data {
        guard SecureEnclave.isAvailable else { throw ProtectedCredentialError.secureEnclaveUnavailable }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.wrappedPrivateKey,
                                                                 authenticationContext: context)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: record.peerPublicKey)
        return Self.derive(try key.sharedSecretFromKeyAgreement(with: peer))
    }

    private static func derive(_ secret: SharedSecret) -> Data {
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: domain,
                                                 sharedInfo: domain, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

nonisolated protocol EnclaveRecordStoring: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

nonisolated struct LegacyEnclaveRecordStore: EnclaveRecordStoring {
    let service: String
    init(service: String = "com.stevenha.MacPearl.enclave-credential.v1") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "primary",
         kSecUseDataProtectionKeychain as String: false]
    }

    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProtectedCredentialError.keychain(status)
        }
        return data
    }

    func write(_ data: Data) throws {
        try Task.checkCancellation()
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // No SecAccessControl or LAContext here: those select the entitlement-
            // gated Keychain. The Enclave key blob itself carries user presence.
            let add = SecItemAdd(item as CFDictionary, nil)
            guard add == errSecSuccess else { throw ProtectedCredentialError.keychain(add) }
        } else if status != errSecSuccess { throw ProtectedCredentialError.keychain(status) }
    }

    func delete() throws {
        try Task.checkCancellation()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProtectedCredentialError.keychain(status)
        }
    }
}

nonisolated final class EnclaveProtectedCredentialStore: ProtectedCredentialStoring, @unchecked Sendable {
    private let records: any EnclaveRecordStoring
    private let protector: any EnclaveKeyProtecting
    private let contextLock = NSLock()
    private var context: LAContext?

    init(records: any EnclaveRecordStoring = LegacyEnclaveRecordStore(),
         protector: any EnclaveKeyProtecting = SecureEnclaveKeyProtector()) {
        self.records = records
        self.protector = protector
    }

    func cancelAuthorization() {
        contextLock.lock()
        let current = context
        contextLock.unlock()
        current?.invalidate()
    }

    func credentialHealth() throws -> CredentialHealth {
        guard let data = try records.read() else { return .absent }
        do { _ = try decode(data); return .complete }
        catch { return .repairPending }
    }

    func hasStoredCredential() throws -> Bool { try credentialHealth() == .complete }

    func save(password: String) throws -> ProtectedCredentialMaterial {
        try withContext { context in
            let previous = try records.read().flatMap { try? decode($0) }
            let key: EnclaveCredentialKey
            if let previous {
                key = EnclaveCredentialKey(wrappedPrivateKey: previous.wrappedPrivateKey,
                    peerPublicKey: previous.peerPublicKey, keyData: try protector.unlock(previous, context: context))
            } else { key = try protector.create(context: context) }
            try Task.checkCancellation()
            let envelope = try ProtectedCredentialCodec().seal(password: password, using: key.keyData)
            let data = try JSONEncoder().encode(envelope)
            let record = EnclaveCredentialRecord(version: EnclaveCredentialRecord.currentVersion,
                wrappedPrivateKey: key.wrappedPrivateKey, peerPublicKey: key.peerPublicKey, envelopeData: data)
            try record.validate()
            // One atomic Keychain record replaces the old value only after
            // authorization and encryption succeed. No partial key/envelope pair.
            try records.write(JSONEncoder().encode(record))
            return ProtectedCredentialMaterial(envelopeData: data, keyData: key.keyData)
        }
    }

    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial {
        guard let data = try records.read() else { throw ProtectedCredentialError.notConfigured }
        let record = try decode(data)
        return try withContext { context in
            let key = try protector.unlock(record, context: context)
            try Task.checkCancellation()
            _ = try ProtectedCredentialCodec().open(JSONDecoder().decode(ProtectedCredentialEnvelope.self,
                from: record.envelopeData), using: key)
            return ProtectedCredentialMaterial(envelopeData: record.envelopeData, keyData: key)
        }
    }

    func delete() throws { try records.delete() }

    private func decode(_ data: Data) throws -> EnclaveCredentialRecord {
        let record = try JSONDecoder().decode(EnclaveCredentialRecord.self, from: data)
        try record.validate()
        return record
    }

    private func withContext<T>(_ body: (LAContext) throws -> T) throws -> T {
        try Task.checkCancellation()
        let current = LAContext()
        current.localizedReason = "Authorize MacPearl to prepare automatic unlock"
        current.touchIDAuthenticationAllowableReuseDuration = 0
        contextLock.lock()
        context = current
        contextLock.unlock()
        defer {
            current.invalidate()
            contextLock.lock()
            if context === current { context = nil }
            contextLock.unlock()
        }
        return try body(current)
    }
}

nonisolated enum CredentialStoreSelection {
    static let freeStorage = "secure-enclave-v1"
    static func make(bundle: Bundle = .main) -> any ProtectedCredentialStoring {
        if bundle.object(forInfoDictionaryKey: "MacPearlCredentialStorage") as? String == freeStorage {
            return EnclaveProtectedCredentialStore()
        }
        return KeychainProtectedCredentialStore()
    }
}
