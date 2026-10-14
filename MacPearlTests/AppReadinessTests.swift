import XCTest
@testable import MacPearl

@MainActor
final class AppReadinessTests: XCTestCase {
    private func readiness(completed: Bool = true, face: Bool = true, camera: Bool = true,
                           accessibility: Bool = true, stored: Bool = true,
                           status: ProtectedCredentialStatus = .sessionReady) -> AppReadiness {
        .evaluate(completed: completed, hasFace: face, camera: camera,
                  accessibility: accessibility, stored: stored, credentials: status)
    }
    func testIncompleteSetupCannotEnableUnlock() { XCTAssertEqual(readiness(completed: false), .setupRequired) }
    func testMissingFaceCannotEnableUnlock() { XCTAssertEqual(readiness(face: false), .setupRequired) }
    func testMissingPasswordCannotEnableUnlock() { XCTAssertEqual(readiness(stored: false), .setupRequired) }
    func testMissingCameraNeedsAttention() {
        XCTAssertEqual(readiness(camera: false), .attention("Allow Camera access in System Settings."))
    }
    func testMissingAccessibilityNeedsAttention() {
        XCTAssertEqual(readiness(accessibility: false), .attention("Allow Accessibility access in System Settings."))
    }
    func testStoredPasswordStillRequiresAuthorization() { XCTAssertEqual(readiness(status: .configured), .authorizationRequired) }
    func testPendingAuthorizationIsNotReady() { XCTAssertEqual(readiness(status: .working("Waiting")), .authorizing) }
    func testFailureIsNotReady() { XCTAssertEqual(readiness(status: .failed("Cancelled")), .attention("Cancelled")) }
    func testAuthorizedCompleteSetupIsReady() { XCTAssertEqual(readiness(), .ready) }

    func testCredentialAuthorizationAndClearSession() async throws {
        let controller = ProtectedCredentialController(store: TestCredentialStore(), validator: AcceptingPasswordValidator())
        controller.prepareSession()
        XCTAssertTrue(controller.isBusy)
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.status, .sessionReady)
        XCTAssertEqual(controller.withCachedPassword { $0 }, "test-password")
        controller.clearSession()
        XCTAssertEqual(controller.status, .configured)
        XCTAssertNil(controller.withCachedPassword { $0 })
    }

    func testCancelledAuthorizationCannotRestoreSession() async throws {
        let controller = ProtectedCredentialController(store: TestCredentialStore(), validator: AcceptingPasswordValidator())
        controller.prepareSession()
        controller.cancelAuthorization()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(controller.status, .configured)
        XCTAssertNil(controller.withCachedPassword { $0 })
    }

    func testInvalidPasswordDoesNotReplaceStoredCredential() async throws {
        let store = MutationCredentialStore(stored: true, blocks: false)
        let controller = ProtectedCredentialController(store: store, validator: RejectingPasswordValidator())
        controller.save(password: "wrong-password")
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.didMutate)
        XCTAssertTrue(controller.hasStoredCredential)
        XCTAssertNil(controller.withCachedPassword { $0 })
        XCTAssertEqual(controller.status, .failed(ProtectedCredentialError.passwordVerificationFailed.localizedDescription))
    }

    func testCancelledSaveReconcilesPersistedStateWithoutAuthorizing() async throws {
        let store = MutationCredentialStore(stored: false)
        let controller = ProtectedCredentialController(store: store, validator: AcceptingPasswordValidator())
        controller.save(password: "test-password")
        for _ in 0..<100 where !store.didMutate { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.didMutate)
        controller.cancelAuthorization()
        store.release.signal()
        for _ in 0..<100 where !controller.hasStoredCredential { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.hasStoredCredential)
        XCTAssertEqual(controller.status, .configured)
        XCTAssertNil(controller.withCachedPassword { $0 })
    }

    func testCancelledDeletionReconcilesPersistedStateWithoutAuthorizing() async throws {
        let store = MutationCredentialStore(stored: true)
        let controller = ProtectedCredentialController(store: store, validator: AcceptingPasswordValidator())
        controller.delete()
        for _ in 0..<100 where !store.didMutate { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.didMutate)
        controller.cancelAuthorization()
        store.release.signal()
        for _ in 0..<100 where controller.hasStoredCredential { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.hasStoredCredential)
        XCTAssertEqual(controller.status, .unavailable)
        XCTAssertNil(controller.withCachedPassword { $0 })
    }

    func testFailedSubmissionClearsAuthorizationUntilVerification() async throws {
        let controller = ProtectedCredentialController(store: TestCredentialStore(), validator: AcceptingPasswordValidator())
        controller.prepareSession()
        for _ in 0..<100 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.status, .sessionReady)
        controller.requirePasswordVerification()
        XCTAssertTrue(controller.hasStoredCredential)
        XCTAssertNil(controller.withCachedPassword { $0 })
        guard case .failed = controller.status else { return XCTFail("Must require verification") }
    }
}

nonisolated private struct RejectingPasswordValidator: SystemPasswordValidating {
    func validate(_ password: String) throws { throw ProtectedCredentialError.passwordVerificationFailed }
}

nonisolated private final class MutationCredentialStore: ProtectedCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    private var mutated = false
    private let blocks: Bool
    let release = DispatchSemaphore(value: 0)
    init(stored: Bool, blocks: Bool = true) { self.stored = stored; self.blocks = blocks }
    var didMutate: Bool { lock.lock(); defer { lock.unlock() }; return mutated }
    func hasStoredCredential() throws -> Bool { lock.lock(); defer { lock.unlock() }; return stored }
    private func mutate(to value: Bool) {
        lock.lock(); stored = value; mutated = true; lock.unlock()
        if blocks { _ = release.wait(timeout: .now() + 3) }
    }
    func save(password: String) throws -> ProtectedCredentialMaterial {
        let material = try TestCredentialStore().save(password: password)
        mutate(to: true)
        return material
    }
    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial { try TestCredentialStore().loadAuthorizedMaterial() }
    func delete() throws { mutate(to: false) }
}

nonisolated private struct AcceptingPasswordValidator: SystemPasswordValidating {
    func validate(_ password: String) throws {}
}

nonisolated private struct TestCredentialStore: ProtectedCredentialStoring {
    func hasStoredCredential() throws -> Bool { true }
    func save(password: String) throws -> ProtectedCredentialMaterial {
        let key = Data(repeating: 7, count: 32)
        let envelope = try ProtectedCredentialCodec().seal(password: password, using: key)
        return ProtectedCredentialMaterial(envelopeData: try JSONEncoder().encode(envelope), keyData: key)
    }
    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial { try save(password: "test-password") }
    func delete() throws {}
}
