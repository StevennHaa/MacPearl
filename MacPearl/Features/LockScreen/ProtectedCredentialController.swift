import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated struct ProtectedCredentialEnvelope: Codable, Equatable, Sendable {
    let version: Int
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    static let currentVersion = 1
}

nonisolated struct ProtectedCredentialCodec: Sendable {
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

nonisolated enum ProtectedCredentialError: LocalizedError, Equatable {
    case invalidKey
    case invalidEnvelope
    case notConfigured
    case missingEncryptionKey
    case authorizationRequired
    case passwordVerificationFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey: "The credential encryption key is invalid."
        case .invalidEnvelope: "The stored credential could not be decrypted."
        case .notConfigured: "Automatic unlock is not configured."
        case .missingEncryptionKey:
            "The protected encryption key is missing. Remove the stored password and set it up again while signed in."
        case .authorizationRequired: "Authorize MacPearl while signed in before locking."
        case .passwordVerificationFailed: "macOS could not verify this login password. Check your current Mac password and try again."
        case .keychain(let status): "The protected credential could not be accessed (Keychain error \(status))."
        }
    }
}

nonisolated protocol ProtectedCredentialStoring: Sendable {
    func hasStoredCredential() throws -> Bool
    func save(password: String) throws -> ProtectedCredentialMaterial
    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial
    func delete() throws
    nonisolated func cancelAuthorization()
}

extension ProtectedCredentialStoring {
    nonisolated func cancelAuthorization() {}
}

nonisolated struct ProtectedCredentialMaterial: Sendable {
    let envelopeData: Data
    let keyData: Data
}

nonisolated struct ProtectedCredentialSaveTransaction {
    func save(
        password: String,
        readExistingKey: () throws -> Data?,
        createAuthorizedKey: () throws -> Data,
        writeEnvelope: (Data) throws -> Void
    ) throws -> ProtectedCredentialMaterial {
        guard !password.isEmpty else { throw ProtectedCredentialError.invalidEnvelope }
        // Authenticate before changing ciphertext. Reusing the protected key
        // makes the envelope the only mutable record and its write atomic.
        let key = try readExistingKey() ?? createAuthorizedKey()
        let envelope = try ProtectedCredentialCodec().seal(password: password, using: key)
        let data = try JSONEncoder().encode(envelope)
        try writeEnvelope(data)
        return ProtectedCredentialMaterial(envelopeData: data, keyData: key)
    }
}

nonisolated final class KeychainProtectedCredentialStore: ProtectedCredentialStoring, @unchecked Sendable {
    private let service = "com.stevenha.MacPearl.unlock-credential"
    private let account = "primary"
    private let keyAccount = "encryption-key"
    private let contextLock = NSLock()
    nonisolated(unsafe) private var authorizationContext: LAContext?

    nonisolated func cancelAuthorization() {
        contextLock.lock()
        let context = authorizationContext
        contextLock.unlock()
        context?.invalidate()
    }
    func hasStoredCredential() throws -> Bool {
        try hasItem(account: account) && hasItem(account: keyAccount)
    }

    func save(password: String) throws -> ProtectedCredentialMaterial {
        try ProtectedCredentialSaveTransaction().save(
            password: password,
            readExistingKey: { try self.hasItem(account: self.keyAccount) ? self.loadAuthorizedKey() : nil },
            createAuthorizedKey: {
                guard try !self.hasItem(account: self.account) else {
                    throw ProtectedCredentialError.missingEncryptionKey
                }
                try self.createProtectedKey()
                return try self.loadAuthorizedKey()
            },
            writeEnvelope: {
                try Task.checkCancellation()
                try self.replace(query: self.baseQuery(account: self.account), value: $0)
            }
        )
    }

    private func createProtectedKey() throws {
        let keyData = try randomKey()
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
        // If another instance just created the key, read that key rather than
        // overwrite it and invalidate the other instance's encrypted password.
        if keyStatus != errSecSuccess && keyStatus != errSecDuplicateItem {
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

        return ProtectedCredentialMaterial(envelopeData: envelopeData, keyData: try loadAuthorizedKey())
    }

    private func loadAuthorizedKey() throws -> Data {
        var keyQuery = baseQuery(account: keyAccount)
        keyQuery[kSecReturnData as String] = true
        let context = LAContext()
        context.localizedReason = "Authorize MacPearl to prepare automatic unlock"
        contextLock.lock()
        authorizationContext = context
        contextLock.unlock()
        defer {
            contextLock.lock()
            if authorizationContext === context { authorizationContext = nil }
            contextLock.unlock()
        }
        try Task.checkCancellation()
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
        return keyData
    }

    func delete() throws {
        try Task.checkCancellation()
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
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecInteractionNotAllowed else {
            throw ProtectedCredentialError.keychain(status)
        }
        return status != errSecItemNotFound
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
    case working(String)

    var message: String {
        switch self {
        case .unavailable: "Automatic unlock is not configured"
        case .configured: "Credential stored; authorize before locking"
        case .sessionReady: "Automatic unlock is authorized until MacPearl quits"
        case .failed(let message): message
        case .working(let message): message
        }
    }
}

@MainActor
final class ProtectedCredentialController: ObservableObject {
    @Published private(set) var status: ProtectedCredentialStatus = .unavailable
    @Published private(set) var isBusy = false
    @Published private(set) var hasStoredCredential = false

    private let store: any ProtectedCredentialStoring
    private let codec = ProtectedCredentialCodec()
    // Like Glance, keep the user-authorized session key—not the plaintext
    // password—in memory so the lock-screen path needs no Keychain prompt.
    private var cachedMaterial: ProtectedCredentialMaterial?
    private let worker: CredentialWorker
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    init(store: (any ProtectedCredentialStoring)? = nil, validator: any SystemPasswordValidating = SystemPasswordValidator()) {
        self.store = store ?? KeychainProtectedCredentialStore()
        worker = CredentialWorker(store: self.store, validator: validator)
        do {
            hasStoredCredential = try self.store.hasStoredCredential()
            status = hasStoredCredential ? .configured : .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    var isConfigured: Bool {
        hasStoredCredential
    }

    func save(password: String) {
        perform(.save(password))
    }

    func prepareSession() {
        perform(.authorize)
    }

    func clearSession() {
        cancelAuthorization()
        cachedMaterial = nil
        status = hasStoredCredential ? .configured : .unavailable
    }

    func delete() {
        perform(.delete)
    }

    func requirePasswordVerification() {
        clearSession()
        status = .failed("Automatic unlock did not complete. Verify or update your Mac password before trying again.")
    }

    func cancelAuthorization() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        store.cancelAuthorization()
        isBusy = false
        if case .working = status { status = hasStoredCredential ? .configured : .unavailable }
    }

    private func perform(_ request: CredentialRequest) {
        cancelAuthorization()
        let id = UUID()
        operationID = id
        cachedMaterial = nil
        isBusy = true
        status = .working(request.message)
        operation = Task { [weak self, worker] in
            do {
                let material = try await worker.run(request)
                guard !Task.isCancelled, let self, self.operationID == id else {
                    await self?.reconcileStoredState()
                    return
                }
                self.cachedMaterial = material
                self.hasStoredCredential = material != nil
                self.status = material == nil ? .unavailable : .sessionReady
                self.isBusy = false
                self.operation = nil
            } catch {
                guard !Task.isCancelled, let self, self.operationID == id else {
                    await self?.reconcileStoredState()
                    return
                }
                self.status = .failed(error.localizedDescription)
                self.isBusy = false
                self.operation = nil
            }
        }
    }

    private func reconcileStoredState() async {
        let generation = operationID
        let stored = await worker.hasCredential()
        guard operationID == generation, !isBusy, let stored else { return }
        hasStoredCredential = stored
        if cachedMaterial == nil, status == .configured || status == .unavailable {
            status = stored ? .configured : .unavailable
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

private enum CredentialRequest: Sendable {
    case save(String), authorize, delete
    var message: String {
        switch self {
        case .save: "Saving and authorizing…"
        case .authorize: "Authorizing…"
        case .delete: "Removing stored password…"
        }
    }
}

private actor CredentialWorker {
    let store: any ProtectedCredentialStoring
    let validator: any SystemPasswordValidating
    init(store: any ProtectedCredentialStoring, validator: any SystemPasswordValidating) {
        self.store = store
        self.validator = validator
    }
    func hasCredential() -> Bool? { try? store.hasStoredCredential() }

    func run(_ request: CredentialRequest) throws -> ProtectedCredentialMaterial? {
        try Task.checkCancellation()
        let material: ProtectedCredentialMaterial
        switch request {
        case .save(let password):
            try validator.validate(password)
            try Task.checkCancellation()
            material = try store.save(password: password)
        case .authorize: material = try store.loadAuthorizedMaterial()
        case .delete:
            try store.delete()
            return nil
        }
        // A corrupt or mismatched record must not report an authorized session.
        let password = try ProtectedCredentialCodec().open(
            JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: material.envelopeData),
            using: material.keyData
        )
        if case .authorize = request { try validator.validate(password) }
        try Task.checkCancellation()
        return material
    }
}
