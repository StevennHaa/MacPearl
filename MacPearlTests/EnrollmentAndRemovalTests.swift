import XCTest
@testable import MacPearl

@MainActor
final class EnrollmentAndRemovalTests: XCTestCase {
    private func template(oldModel: Bool = false, oldPreprocessing: Bool = false) throws -> UserFaceTemplate {
        let current = FaceEmbeddingModelProvider.metadata
        let metadata = oldModel ? FaceEmbeddingModelMetadata(
            name: current.name, version: "previous-model", license: current.license, source: current.source
        ) : current
        let embedding = try FaceEmbedding(values: [1] + Array(repeating: 0, count: 511))
        return UserFaceTemplate(id: UUID(), createdAt: Date(), model: metadata,
                                preprocessingVersion: oldPreprocessing ? "previous-preprocessing" : FaceImagePreprocessor.version,
                                embeddings: Dictionary(uniqueKeysWithValues: FaceCapturePose.allCases.map { ($0, embedding) }))
    }

    func testModelUpgradeRequiresReenrollmentAndCannotReportReady() throws {
        let store = RemovalTemplateStore(try template(oldModel: true))
        let enrollment = EnrollmentController(templateStore: store)
        XCTAssertNil(enrollment.template)
        XCTAssertTrue(enrollment.requiresReenrollment)
        guard case .failed(let message) = enrollment.state else { return XCTFail("Expected recovery guidance") }
        XCTAssertTrue(message.contains("Enroll"))
        XCTAssertThrowsError(try FaceTemplateMatcher(template: XCTUnwrap(store.load()), threshold: 0.55))
        XCTAssertEqual(AppReadiness.evaluate(completed: true, hasFace: enrollment.template != nil,
                                             camera: true, accessibility: true, stored: true,
                                             credentials: .sessionReady), .setupRequired)
        XCTAssertEqual(SetupStep.initial(completed: true, camera: true, accessibility: true,
                                         hasFace: enrollment.template != nil,
                                         requiresReenrollment: enrollment.requiresReenrollment,
                                         credentialsReady: true), .enrollment)
        XCTAssertEqual(SetupStep.initial(completed: true, camera: false, accessibility: true,
                                         hasFace: false, requiresReenrollment: true,
                                         credentialsReady: true), .permissions)
    }

    func testPreprocessingUpgradeRequiresReenrollmentEvenWithAlternateStore() throws {
        let enrollment = EnrollmentController(templateStore: RemovalTemplateStore(try template(oldPreprocessing: true)))
        XCTAssertNil(enrollment.template)
        XCTAssertTrue(enrollment.requiresReenrollment)
    }

    func testCompatibleReplacementRecoversEnrollmentOnReload() throws {
        let store = RemovalTemplateStore(try template(oldModel: true))
        let enrollment = EnrollmentController(templateStore: store)
        let replacement = try template()
        try store.save(replacement)
        enrollment.reloadTemplate()
        XCTAssertFalse(enrollment.requiresReenrollment)
        XCTAssertEqual(enrollment.template, replacement)
        XCTAssertNoThrow(try FaceTemplateMatcher(template: XCTUnwrap(enrollment.template), threshold: 0.55))
    }

    func testDeletingFaceClearsMemoryAndPersistentTemplate() throws {
        let store = RemovalTemplateStore(try template())
        let enrollment = EnrollmentController(templateStore: store)
        try enrollment.deleteTemplate()
        XCTAssertNil(enrollment.template)
        XCTAssertNil(try store.load())
        enrollment.reloadTemplate()
        XCTAssertNil(enrollment.template)
    }

    func testPausePersistsAndClearsAuthorizedPassword() async throws {
        let (session, defaults, suite) = try session()
        defer { defaults.removePersistentDomain(forName: suite); session.shutdown() }
        try await authorize(session.credentials)
        session.pauseAutomaticUnlock()
        XCTAssertTrue(session.isPaused)
        XCTAssertTrue(defaults.bool(forKey: "automaticUnlockPaused"))
        XCTAssertEqual(session.readiness, .paused)
        XCTAssertNil(session.credentials.withCachedPassword { $0 })
        XCTAssertFalse(session.recognition.isLockedSessionActive)
        let relaunched = AppSessionController(defaults: defaults,
                                             templateStore: RemovalTemplateStore(try template()),
                                             credentialController: ProtectedCredentialController(store: RemovalCredentialStore(), validator: RemovalTestPasswordValidator()),
                                             currentLockState: { false })
        defer { relaunched.shutdown() }
        XCTAssertTrue(relaunched.isPaused)
        XCTAssertEqual(relaunched.readiness, .paused)
    }

    func testFailedFaceRemovalStaysPausedAndDoesNotClaimDeletion() async throws {
        let store = RemovalTemplateStore(try template(), failDeletion: true)
        let (session, defaults, suite) = try session(store: store)
        defer { defaults.removePersistentDomain(forName: suite); session.shutdown() }
        try await authorize(session.credentials)
        session.deleteFace()
        XCTAssertTrue(session.isPaused)
        XCTAssertNotNil(try store.load())
        XCTAssertNil(session.enrollment.template)
        XCTAssertNil(session.credentials.withCachedPassword { $0 })
        XCTAssertTrue(session.removalMessage?.contains("could not be removed") == true)
        XCTAssertEqual(session.readiness, .paused)
    }

    func testPasswordRemovalDisarmsBeforeAsyncDeletion() async throws {
        let credentials = ProtectedCredentialController(store: RemovalCredentialStore(), validator: RemovalTestPasswordValidator())
        let (session, defaults, suite) = try session(credentials: credentials)
        defer { defaults.removePersistentDomain(forName: suite); session.shutdown() }
        try await authorize(credentials)
        session.removeStoredPassword()
        XCTAssertTrue(session.isPaused)
        XCTAssertNil(credentials.withCachedPassword { $0 })
        for _ in 0..<100 where credentials.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(credentials.isBusy)
        XCTAssertFalse(credentials.hasStoredCredential)
        XCTAssertEqual(credentials.status, .unavailable)
    }

    func testFailedPasswordRemovalKeepsCredentialButClearsAuthorization() async throws {
        let credentials = ProtectedCredentialController(store: RemovalCredentialStore(failDeletion: true), validator: RemovalTestPasswordValidator())
        let (session, defaults, suite) = try session(credentials: credentials)
        defer { defaults.removePersistentDomain(forName: suite); session.shutdown() }
        try await authorize(credentials)
        session.removeStoredPassword()
        for _ in 0..<100 where credentials.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(credentials.hasStoredCredential)
        XCTAssertNil(credentials.withCachedPassword { $0 })
        XCTAssertEqual(session.readiness, .paused)
        guard case .failed = credentials.status else { return XCTFail("Expected visible deletion failure") }
    }

    func testSuccessfulPasswordUpdateExitsEntryModeDuringInitialSetup() async throws {
        let (session, defaults, suite) = try session(completed: false)
        defer { defaults.removePersistentDomain(forName: suite); session.shutdown() }
        session.updatePassword()
        XCTAssertTrue(session.isUpdatingPassword)
        session.credentials.save(password: "replacement-password")
        for _ in 0..<100 where session.credentials.isBusy || session.isUpdatingPassword {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.credentials.status, .sessionReady)
        XCTAssertFalse(session.isUpdatingPassword)
        XCTAssertEqual(session.credentials.withCachedPassword { $0 }, "replacement-password")
        XCTAssertEqual(session.step, .credential)
        XCTAssertTrue(session.setupVisible)
        XCTAssertFalse(defaults.bool(forKey: "setupCompleted"))
    }

    func testFailedPasswordUpdateKeepsEntryModeForRetry() async throws {
        let credentials = ProtectedCredentialController(store: RemovalCredentialStore(),
                                                        validator: RemovalTestPasswordValidator(reject: true))
        let (session, defaults, suite) = try session(credentials: credentials, completed: false)
        defer { defaults.removePersistentDomain(forName: suite); session.shutdown() }
        session.updatePassword()
        credentials.save(password: "wrong-password")
        for _ in 0..<100 where credentials.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        session.refresh()
        XCTAssertEqual(credentials.status, .failed(ProtectedCredentialError.passwordVerificationFailed.localizedDescription))
        XCTAssertTrue(session.isUpdatingPassword)
        XCTAssertNil(credentials.withCachedPassword { $0 })
    }

    func testCanceledPasswordUpdateKeepsEntryModeWithoutAuthorizing() async throws {
        let (session, defaults, suite) = try session(completed: false)
        defer { defaults.removePersistentDomain(forName: suite); session.shutdown() }
        session.updatePassword()
        session.credentials.save(password: "replacement-password")
        session.credentials.cancelAuthorization()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.isUpdatingPassword)
        XCTAssertNotEqual(session.credentials.status, .sessionReady)
        XCTAssertNil(session.credentials.withCachedPassword { $0 })
    }

    private func session(store: RemovalTemplateStore? = nil, credentials: ProtectedCredentialController? = nil,
                         completed: Bool = true) throws -> (AppSessionController, UserDefaults, String) {
        let suite = "MacPearlRemovalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(completed, forKey: "setupCompleted")
        let session = AppSessionController(defaults: defaults,
                                          templateStore: try store ?? RemovalTemplateStore(template()),
                                          credentialController: credentials ?? ProtectedCredentialController(store: RemovalCredentialStore(), validator: RemovalTestPasswordValidator()),
                                          currentLockState: { false })
        return (session, defaults, suite)
    }

    private func authorize(_ credentials: ProtectedCredentialController) async throws {
        credentials.prepareSession()
        for _ in 0..<100 where credentials.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(credentials.status, .sessionReady)
        XCTAssertNotNil(credentials.withCachedPassword { $0 })
    }
}

nonisolated private final class RemovalTemplateStore: FaceTemplateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var template: UserFaceTemplate?
    private let failDeletion: Bool
    init(_ template: UserFaceTemplate?, failDeletion: Bool = false) { self.template = template; self.failDeletion = failDeletion }
    func load() throws -> UserFaceTemplate? { lock.lock(); defer { lock.unlock() }; return template }
    func save(_ template: UserFaceTemplate) throws { lock.lock(); defer { lock.unlock() }; self.template = template }
    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        if failDeletion { throw FaceTemplateStoreError.keychain(-1) }
        template = nil
    }
}

nonisolated private final class RemovalCredentialStore: ProtectedCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = true
    private let failDeletion: Bool
    init(failDeletion: Bool = false) { self.failDeletion = failDeletion }
    func hasStoredCredential() throws -> Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func save(password: String) throws -> ProtectedCredentialMaterial {
        let key = Data(repeating: 7, count: 32)
        let envelope = try ProtectedCredentialCodec().seal(password: password, using: key)
        return ProtectedCredentialMaterial(envelopeData: try JSONEncoder().encode(envelope), keyData: key)
    }
    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial { try save(password: "test-password") }
    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        if failDeletion { throw ProtectedCredentialError.notConfigured }
        stored = false
    }
}

nonisolated private struct RemovalTestPasswordValidator: SystemPasswordValidating {
    var reject = false
    func validate(_ password: String) throws {
        if reject { throw ProtectedCredentialError.passwordVerificationFailed }
    }
}
