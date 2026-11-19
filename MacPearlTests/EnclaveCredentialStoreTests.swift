import CryptoKit
import LocalAuthentication
import XCTest
@testable import MacPearl

@MainActor
final class EnclaveCredentialStoreTests: XCTestCase {
    func testEncryptedSaveFreshAuthorizationAndDeletion() throws {
        let records = TestEnclaveRecords()
        let protector = TestEnclaveProtector()
        let store = EnclaveProtectedCredentialStore(records: records, protector: protector)
        XCTAssertEqual(try store.credentialHealth(), .absent)
        let material = try store.save(password: "synthetic-password")
        XCTAssertEqual(try store.credentialHealth(), .complete)
        XCTAssertNil(records.data?.range(of: Data("synthetic-password".utf8)))
        let restored = try store.loadAuthorizedMaterial()
        XCTAssertEqual(material.keyData, restored.keyData)
        XCTAssertEqual(try ProtectedCredentialCodec().open(
            JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: restored.envelopeData),
            using: restored.keyData), "synthetic-password")
        XCTAssertEqual(protector.creates, 1)
        XCTAssertEqual(protector.unlocks, 1)
        XCTAssertFalse(protector.contexts[0] === protector.contexts[1])
        try store.delete()
        XCTAssertEqual(try store.credentialHealth(), .absent)
    }

    func testDeniedFirstAuthorizationWritesNothing() {
        let records = TestEnclaveRecords()
        let protector = TestEnclaveProtector()
        protector.deny = true
        let store = EnclaveProtectedCredentialStore(records: records, protector: protector)
        XCTAssertThrowsError(try store.save(password: "synthetic-password"))
        XCTAssertNil(records.data)
    }

    func testCanceledUpdatePreservesOriginalRecord() throws {
        let records = TestEnclaveRecords()
        let protector = TestEnclaveProtector()
        let store = EnclaveProtectedCredentialStore(records: records, protector: protector)
        _ = try store.save(password: "original")
        let before = records.data
        protector.deny = true
        XCTAssertThrowsError(try store.save(password: "replacement"))
        XCTAssertEqual(records.data, before)
        protector.deny = false
        let material = try store.loadAuthorizedMaterial()
        XCTAssertEqual(try ProtectedCredentialCodec().open(
            JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: material.envelopeData),
            using: material.keyData), "original")
    }

    func testFailedAtomicWritePreservesExistingCredential() throws {
        let records = TestEnclaveRecords()
        let store = EnclaveProtectedCredentialStore(records: records, protector: TestEnclaveProtector())
        _ = try store.save(password: "original")
        let before = records.data
        records.rejectWrites = true
        XCTAssertThrowsError(try store.save(password: "replacement"))
        XCTAssertEqual(records.data, before)
    }

    func testTamperedCiphertextCannotAuthorize() throws {
        let records = TestEnclaveRecords()
        let store = EnclaveProtectedCredentialStore(records: records, protector: TestEnclaveProtector())
        _ = try store.save(password: "original")
        let previous = try JSONDecoder().decode(EnclaveCredentialRecord.self, from: XCTUnwrap(records.data))
        let envelope = try JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: previous.envelopeData)
        var ciphertext = envelope.ciphertext
        ciphertext[0] ^= 1
        let changed = ProtectedCredentialEnvelope(version: envelope.version, nonce: envelope.nonce,
                                                  ciphertext: ciphertext, tag: envelope.tag)
        records.data = try JSONEncoder().encode(EnclaveCredentialRecord(version: previous.version,
            wrappedPrivateKey: previous.wrappedPrivateKey, peerPublicKey: previous.peerPublicKey,
            envelopeData: JSONEncoder().encode(changed)))
        XCTAssertThrowsError(try store.loadAuthorizedMaterial())
    }

    func testUnsupportedRecordCannotUnlockAndRequiresExplicitRepair() throws {
        let records = TestEnclaveRecords()
        let protector = TestEnclaveProtector()
        let store = EnclaveProtectedCredentialStore(records: records, protector: protector)
        records.data = Data("{\"version\":99}".utf8)
        XCTAssertEqual(try store.credentialHealth(), .repairPending)
        XCTAssertThrowsError(try store.loadAuthorizedMaterial())
        XCTAssertEqual(protector.unlocks, 0)
        protector.deny = true
        let before = records.data
        XCTAssertThrowsError(try store.save(password: "replacement"))
        XCTAssertEqual(records.data, before)
    }

    func testDeletionFailureRemainsVisibleAndPreservesRecord() throws {
        let records = TestEnclaveRecords()
        let store = EnclaveProtectedCredentialStore(records: records, protector: TestEnclaveProtector())
        _ = try store.save(password: "original")
        records.rejectDeletion = true
        XCTAssertThrowsError(try store.delete())
        XCTAssertEqual(try store.credentialHealth(), .complete)
    }
}

nonisolated private final class TestEnclaveRecords: EnclaveRecordStoring, @unchecked Sendable {
    var data: Data?
    var rejectWrites = false
    var rejectDeletion = false
    func read() throws -> Data? { data }
    func write(_ value: Data) throws {
        if rejectWrites { throw ProtectedCredentialError.keychain(-50) }
        data = value
    }
    func delete() throws {
        if rejectDeletion { throw ProtectedCredentialError.keychain(-50) }
        data = nil
    }
}

nonisolated private final class TestEnclaveProtector: EnclaveKeyProtecting, @unchecked Sendable {
    var deny = false
    var creates = 0
    var unlocks = 0
    var contexts: [LAContext] = []
    private let key = Data(repeating: 27, count: 32)
    func create(context: LAContext) throws -> EnclaveCredentialKey {
        contexts.append(context)
        creates += 1
        if deny { throw CancellationError() }
        return EnclaveCredentialKey(wrappedPrivateKey: Data([1,2,3]),
            peerPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, keyData: key)
    }
    func unlock(_ record: EnclaveCredentialRecord, context: LAContext) throws -> Data {
        contexts.append(context)
        unlocks += 1
        if deny { throw CancellationError() }
        return key
    }
}
