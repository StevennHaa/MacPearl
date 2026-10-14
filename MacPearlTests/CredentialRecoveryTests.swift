import XCTest
@testable import MacPearl

@MainActor
final class CredentialRecoveryTests: XCTestCase {
    func testKeyRecoveryDoesNotMutateLiveRecordsBeforeAuthorization() {
        var events: [String] = []
        XCTAssertThrowsError(try ProtectedCredentialKeyRecovery().recover(
            authorize: { events.append("authorize"); throw ProtectedCredentialError.authorizationRequired },
            markPending: { events.append("marker") }, publishKey: { key in events.append("key"); return key }
        ))
        XCTAssertEqual(events, ["authorize"])
    }

    func testKeyPublicationFailureRetainsRepairMarker() {
        var events: [String] = []
        XCTAssertThrowsError(try ProtectedCredentialKeyRecovery().recover(
            authorize: { events.append("authorize"); return Data(repeating: 4, count: 32) },
            markPending: { events.append("marker") },
            publishKey: { _ in events.append("key"); throw ProtectedCredentialError.keychain(-50) }
        ))
        XCTAssertEqual(events, ["authorize", "marker", "key"])
    }

    func testRecoveryUsesAuthenticatedExistingKeyWhenPublicationCollides() throws {
        let proposed = Data(repeating: 3, count: 32)
        let existing = Data(repeating: 8, count: 32)
        let effective = try ProtectedCredentialKeyRecovery().recover(
            authorize: { proposed }, markPending: {}, publishKey: { _ in existing }
        )
        XCTAssertEqual(effective, existing)
        let envelope = try ProtectedCredentialCodec().seal(password: "current-password", using: effective)
        XCTAssertEqual(try ProtectedCredentialCodec().open(envelope, using: existing), "current-password")
        XCTAssertThrowsError(try ProtectedCredentialCodec().open(envelope, using: proposed))
    }

    func testAllRecordCombinations() {
        XCTAssertEqual(CredentialHealth.classify(envelope: false, key: false, pending: false), .absent)
        XCTAssertEqual(CredentialHealth.classify(envelope: true, key: true, pending: false), .complete)
        XCTAssertEqual(CredentialHealth.classify(envelope: true, key: false, pending: false), .missingKey)
        XCTAssertEqual(CredentialHealth.classify(envelope: false, key: true, pending: false), .missingEnvelope)
        XCTAssertEqual(CredentialHealth.classify(envelope: true, key: true, pending: true), .repairPending)
    }

    func testMissingRecordsOfferRepairWithoutReportingConfigured() {
        for health in [CredentialHealth.missingKey, .missingEnvelope, .repairPending] {
            let controller = make(RecoveryStore(health))
            XCTAssertTrue(controller.needsRepair)
            XCTAssertFalse(controller.hasStoredCredential)
            XCTAssertNotEqual(controller.status, .sessionReady)
        }
    }

    func testBothAbsentUseNormalSetup() {
        let controller = make(RecoveryStore(.absent))
        XCTAssertFalse(controller.needsRepair)
        XCTAssertEqual(controller.status, .unavailable)
    }

    func testHealthyPairUsesNormalAuthorization() async throws {
        let controller = make(RecoveryStore(.complete))
        controller.prepareSession()
        try await settle(controller)
        XCTAssertEqual(controller.status, .sessionReady)
        XCTAssertFalse(controller.needsRepair)
    }

    func testRepairsEachIncompletePair() async throws {
        for health in [CredentialHealth.missingKey, .missingEnvelope, .repairPending] {
            let controller = make(RecoveryStore(health))
            controller.save(password: "current-password")
            try await settle(controller)
            XCTAssertEqual(controller.credentialHealth, .complete)
            XCTAssertEqual(controller.status, .sessionReady)
            XCTAssertEqual(controller.withCachedPassword { $0 }, "current-password")
        }
    }

    func testWrongPasswordNeverMutatesIncompletePair() async throws {
        let store = RecoveryStore(.missingKey)
        let controller = ProtectedCredentialController(store: store, validator: RecoveryValidator(reject: true))
        controller.save(password: "wrong")
        try await settle(controller)
        XCTAssertEqual(try store.credentialHealth(), .missingKey)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertNil(controller.withCachedPassword { $0 })
    }

    func testAuthorizationCancellationPreservesIncompletePair() async throws {
        let store = RecoveryStore(.missingKey, mode: .cancelAuthorization)
        let controller = make(store)
        controller.save(password: "current-password")
        try await settle(controller)
        XCTAssertEqual(try store.credentialHealth(), .missingKey)
        XCTAssertTrue(controller.needsRepair)
        XCTAssertNil(controller.withCachedPassword { $0 })
    }

    func testPartialWriteFailureIsRepairableOnRetry() async throws {
        let store = RecoveryStore(.missingKey, mode: .failOnce)
        let controller = make(store)
        controller.save(password: "current-password")
        try await settle(controller)
        XCTAssertEqual(controller.credentialHealth, .repairPending)
        XCTAssertFalse(controller.hasStoredCredential)
        XCTAssertNil(controller.withCachedPassword { $0 })
        controller.save(password: "current-password")
        try await settle(controller)
        XCTAssertEqual(controller.status, .sessionReady)
        XCTAssertFalse(controller.needsRepair)
    }

    func testCancelAfterRepairCommitReconcilesWithoutAuthorizing() async throws {
        let store = RecoveryStore(.missingKey, mode: .blockAfterCommit)
        let controller = make(store)
        controller.save(password: "current-password")
        for _ in 0..<100 where try store.credentialHealth() != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try store.credentialHealth(), .complete)
        controller.cancelAuthorization()
        store.release.signal()
        for _ in 0..<100 where controller.credentialHealth != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.credentialHealth, .complete)
        XCTAssertNotEqual(controller.status, .sessionReady)
        XCTAssertNil(controller.withCachedPassword { $0 })
    }

    func testStorageAccessErrorIsNotClassifiedAsMissing() {
        let controller = make(RecoveryStore(.complete, mode: .accessError))
        guard case .failed = controller.status else { return XCTFail("Access errors must remain errors") }
        XCTAssertFalse(controller.needsRepair)
    }

    private func make(_ store: RecoveryStore) -> ProtectedCredentialController {
        ProtectedCredentialController(store: store, validator: RecoveryValidator())
    }
    private func settle(_ controller: ProtectedCredentialController) async throws {
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isBusy)
    }
}

nonisolated private struct RecoveryValidator: SystemPasswordValidating {
    var reject = false
    func validate(_ password: String) throws {
        if reject { throw ProtectedCredentialError.passwordVerificationFailed }
    }
}

nonisolated private final class RecoveryStore: ProtectedCredentialStoring, @unchecked Sendable {
    enum Mode { case normal, cancelAuthorization, failOnce, blockAfterCommit, accessError }
    private let lock = NSLock()
    private var health: CredentialHealth
    private var mode: Mode
    private var count = 0
    let release = DispatchSemaphore(value: 0)
    init(_ health: CredentialHealth, mode: Mode = .normal) { self.health = health; self.mode = mode }
    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func credentialHealth() throws -> CredentialHealth {
        lock.lock(); defer { lock.unlock() }
        if mode == .accessError { throw ProtectedCredentialError.keychain(-34018) }
        return health
    }
    func hasStoredCredential() throws -> Bool { try credentialHealth() == .complete }
    func save(password: String) throws -> ProtectedCredentialMaterial {
        lock.lock()
        count += 1
        let action = mode
        if action == .cancelAuthorization {
            lock.unlock()
            throw ProtectedCredentialError.authorizationRequired
        }
        if action == .failOnce {
            health = .repairPending
            mode = .normal
            lock.unlock()
            throw ProtectedCredentialError.keychain(-50)
        }
        health = .complete
        lock.unlock()
        if action == .blockAfterCommit { _ = release.wait(timeout: .now() + 3) }
        return try material(password)
    }
    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial { try material("current-password") }
    private func material(_ password: String) throws -> ProtectedCredentialMaterial {
        let key = Data(repeating: 9, count: 32)
        let envelope = try ProtectedCredentialCodec().seal(password: password, using: key)
        return ProtectedCredentialMaterial(envelopeData: try JSONEncoder().encode(envelope), keyData: key)
    }
    func delete() throws { lock.lock(); health = .absent; lock.unlock() }
}
