import XCTest
import Foundation
@testable import MacPearl

final class Phase5LockMonitoringTests: XCTestCase {
    func testQuartzLockFlagCannotAuthorizeAnotherConsoleAccount() {
        let ownSession: [String: Any] = [
            "kCGSSessionOnConsoleKey": true,
            "kCGSSessionUserIDKey": NSNumber(value: 501),
            "kCGSessionLoginDoneKey": true
        ]
        XCTAssertEqual(ConsoleLockStateResolver.resolve(consoleUsers: [ownSession], consoleLocked: nil, userID: 501, quartzLocked: true), true)
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [ownSession], consoleLocked: nil, userID: 502, quartzLocked: true))
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [], consoleLocked: nil, userID: 501, quartzLocked: true))
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [ownSession], consoleLocked: false, userID: 501, quartzLocked: true))
    }

    func testPasswordBudgetSurvivesSleepWakeAndUncertainState() {
        var budget = LockedSessionAttemptBudget()
        XCTAssertTrue(budget.reserve())
        XCTAssertFalse(budget.update(snapshot: LockSessionSnapshot(isLocked: true, isSleeping: true)))
        XCTAssertFalse(budget.update(snapshot: LockSessionSnapshot(isLocked: true)))
        XCTAssertFalse(budget.update(snapshot: LockSessionSnapshot(isLocked: false)))
        XCTAssertFalse(budget.reserve())
        XCTAssertTrue(budget.update(snapshot: LockSessionSnapshot(confirmedUnlockCount: 1)))
        XCTAssertTrue(budget.reserve())
        XCTAssertFalse(budget.update(snapshot: LockSessionSnapshot(confirmedUnlockCount: 1)))
        XCTAssertFalse(budget.reserve())
    }

    func testUncertainUnlockSignalDoesNotResetAttemptBudget() {
        var reducer = LockSessionEventReducer()
        _ = reducer.receive(.screenLocked, authoritativeLocked: true, at: 1)
        _ = reducer.receive(.screenUnlocked, authoritativeLocked: nil, at: 2)
        XCTAssertEqual(reducer.snapshot.confirmedUnlockCount, 0)
        _ = reducer.receive(.screenUnlocked, authoritativeLocked: true, at: 3)
        XCTAssertEqual(reducer.snapshot.confirmedUnlockCount, 0)
        _ = reducer.receive(.screenUnlocked, authoritativeLocked: false, at: 4)
        XCTAssertEqual(reducer.snapshot.confirmedUnlockCount, 1)
    }

    func testCanceledKeyAuthorizationDoesNotWriteCiphertext() {
        var wrote = false
        XCTAssertThrowsError(try ProtectedCredentialSaveTransaction().save(
            password: "new password",
            readExistingKey: { throw ProtectedCredentialError.authorizationRequired },
            createAuthorizedKey: { XCTFail("Must not replace an existing key"); return Data() },
            writeEnvelope: { _ in wrote = true }
        ))
        XCTAssertFalse(wrote)
        XCTAssertThrowsError(try ProtectedCredentialSaveTransaction().save(
            password: "first password",
            readExistingKey: { nil },
            createAuthorizedKey: { throw ProtectedCredentialError.authorizationRequired },
            writeEnvelope: { _ in wrote = true }
        ))
        XCTAssertFalse(wrote)
    }

    func testFailedCredentialUpdatePreservesPreviousPasswordAndKey() throws {
        let key = Data(repeating: 8, count: 32)
        let previous = try ProtectedCredentialCodec().seal(password: "previous password", using: key)
        var stored = try JSONEncoder().encode(previous)
        XCTAssertThrowsError(try ProtectedCredentialSaveTransaction().save(
            password: "replacement password",
            readExistingKey: { key },
            createAuthorizedKey: { XCTFail("Must reuse the protected key"); return Data() },
            writeEnvelope: { _ in throw ProtectedCredentialError.keychain(-1) }
        ))
        XCTAssertEqual(try ProtectedCredentialCodec().open(JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: stored), using: key), "previous password")
        let material = try ProtectedCredentialSaveTransaction().save(
            password: "replacement password",
            readExistingKey: { key },
            createAuthorizedKey: { XCTFail("Must reuse the protected key"); return Data() },
            writeEnvelope: { stored = $0 }
        )
        XCTAssertEqual(material.keyData, key)
        XCTAssertEqual(try ProtectedCredentialCodec().open(JSONDecoder().decode(ProtectedCredentialEnvelope.self, from: stored), using: key), "replacement password")
    }

    @MainActor
    func testCoordinatorConsumesPublishedLockGenerationImmediately() async throws {
        var checks = 0
        let monitor = LockSessionMonitor(lockStateProvider: {
            checks += 1
            return checks > 1
        })
        let coordinator = LockedSessionRecognitionCoordinator(
            lockSessionMonitor: monitor,
            templateStore: EmptyLockTestTemplateStore(),
            credentialController: ProtectedCredentialController(store: EmptyLockTestCredentialStore())
        )
        monitor.scheduleSettledCheck(.screenLocked)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(monitor.lockedSessionReadyGeneration, 1)
        XCTAssertEqual(coordinator.handledReadyGeneration, 1)
        XCTAssertEqual(coordinator.status, .missingTemplate)
    }

    @MainActor
    func testDelayedLockFlagStartsRecognitionWithoutWakeEvent() async throws {
        var checks = 0
        let monitor = LockSessionMonitor(lockStateProvider: {
            checks += 1
            return checks >= 3
        })
        XCTAssertFalse(monitor.snapshot.isLocked)
        monitor.scheduleSettledCheck(.screenLocked)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(monitor.snapshot.isLocked)
        XCTAssertEqual(monitor.snapshot.lastEvent, .screenLocked)
        XCTAssertEqual(monitor.lockedSessionReadyGeneration, 1)
    }

    func testConsoleFallbackVerifiesCurrentSignedInUser() {
        let session: [String: Any] = [
            "kCGSSessionOnConsoleKey": true,
            "kCGSSessionUserIDKey": NSNumber(value: 501),
            "kCGSessionLoginDoneKey": true
        ]
        XCTAssertEqual(ConsoleLockStateResolver.resolve(consoleUsers: [session], consoleLocked: true, userID: 501), true)
        XCTAssertEqual(ConsoleLockStateResolver.resolve(consoleUsers: [session], consoleLocked: false, userID: 501), false)
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [session], consoleLocked: true, userID: 502))
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [session], consoleLocked: nil, userID: 501))
    }

    func testConsoleFallbackRejectsInactiveAmbiguousAndConflictingSessions() {
        var session: [String: Any] = [
            "kCGSSessionOnConsoleKey": false,
            "kCGSSessionUserIDKey": NSNumber(value: 501),
            "kCGSessionLoginDoneKey": true
        ]
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [session], consoleLocked: true, userID: 501))
        session["kCGSSessionOnConsoleKey"] = true
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [session, session], consoleLocked: true, userID: 501))
        session["kCGSessionLoginDoneKey"] = false
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [session], consoleLocked: true, userID: 501))
        session["kCGSessionLoginDoneKey"] = true
        session["CGSSessionScreenIsLocked"] = false
        XCTAssertNil(ConsoleLockStateResolver.resolve(consoleUsers: [session], consoleLocked: true, userID: 501))
    }

    func testLockSignalRequiresAuthoritativeLockedState() {
        var reducer = LockSessionEventReducer()

        XCTAssertFalse(reducer.receive(.screenLocked, authoritativeLocked: nil, at: 1))
        XCTAssertFalse(reducer.snapshot.isLocked)
        XCTAssertEqual(reducer.snapshot.readyEventCount, 0)

        XCTAssertTrue(reducer.receive(.screenLocked, authoritativeLocked: true, at: 2))
        XCTAssertTrue(reducer.snapshot.isLocked)
        XCTAssertEqual(reducer.snapshot.readyEventCount, 1)
    }

    func testDuplicateWakeAndLockBurstIsDebounced() {
        var reducer = LockSessionEventReducer(debounceInterval: 2)

        XCTAssertTrue(reducer.receive(.screenLocked, authoritativeLocked: true, at: 10))
        XCTAssertFalse(reducer.receive(.screensDidWake, authoritativeLocked: true, at: 10.2))
        XCTAssertFalse(reducer.receive(.systemDidWake, authoritativeLocked: true, at: 10.4))
        XCTAssertEqual(reducer.snapshot.readyEventCount, 1)
    }

    func testUnlockResetsDebounceForNextLockSession() {
        var reducer = LockSessionEventReducer(debounceInterval: 2)

        XCTAssertTrue(reducer.receive(.screenLocked, authoritativeLocked: true, at: 10))
        XCTAssertFalse(reducer.receive(.screenUnlocked, authoritativeLocked: false, at: 10.1))
        XCTAssertTrue(reducer.receive(.screenLocked, authoritativeLocked: true, at: 10.2))
        XCTAssertEqual(reducer.snapshot.readyEventCount, 2)
    }

    func testSleepingSessionNeverBecomesReady() {
        var reducer = LockSessionEventReducer()

        XCTAssertFalse(reducer.receive(.willSleep, authoritativeLocked: true, at: 1))
        XCTAssertTrue(reducer.snapshot.isSleeping)
        XCTAssertEqual(reducer.snapshot.readyEventCount, 0)
    }

    func testLockedSessionLifecycleStartsOncePerReadyGeneration() {
        var lifecycle = LockedSessionRecognitionLifecycle()
        let locked = LockSessionSnapshot(isLocked: true)

        XCTAssertEqual(
            lifecycle.reconcile(snapshot: locked, readyGeneration: 1, hasTemplate: true),
            .start
        )
        XCTAssertTrue(lifecycle.isActive)
        XCTAssertEqual(
            lifecycle.reconcile(snapshot: locked, readyGeneration: 1, hasTemplate: true),
            .none
        )
        XCTAssertEqual(
            lifecycle.reconcile(snapshot: locked, readyGeneration: 2, hasTemplate: true),
            .none
        )
        XCTAssertEqual(lifecycle.handledGeneration, 2)
    }

    func testLockedSessionLifecycleStopsImmediatelyAfterUnlock() {
        var lifecycle = LockedSessionRecognitionLifecycle()
        _ = lifecycle.reconcile(
            snapshot: LockSessionSnapshot(isLocked: true),
            readyGeneration: 1,
            hasTemplate: true
        )

        XCTAssertEqual(
            lifecycle.reconcile(
                snapshot: LockSessionSnapshot(isLocked: false),
                readyGeneration: 1,
                hasTemplate: true
            ),
            .stop
        )
        XCTAssertFalse(lifecycle.isActive)
    }

    func testLockedSessionLifecycleWaitsForPreloadedTemplate() {
        var lifecycle = LockedSessionRecognitionLifecycle()
        let locked = LockSessionSnapshot(isLocked: true)

        XCTAssertEqual(
            lifecycle.reconcile(snapshot: locked, readyGeneration: 1, hasTemplate: false),
            .missingTemplate
        )
        XCTAssertEqual(
            lifecycle.reconcile(snapshot: locked, readyGeneration: 1, hasTemplate: true),
            .start
        )
    }

    func testLockedSessionLifecycleStopsForSleep() {
        var lifecycle = LockedSessionRecognitionLifecycle()
        _ = lifecycle.reconcile(
            snapshot: LockSessionSnapshot(isLocked: true),
            readyGeneration: 1,
            hasTemplate: true
        )

        XCTAssertEqual(
            lifecycle.reconcile(
                snapshot: LockSessionSnapshot(isLocked: true, isSleeping: true),
                readyGeneration: 1,
                hasTemplate: true
            ),
            .stop
        )
    }

    func testProtectedCredentialCodecRoundTripsWithoutPlaintextEnvelope() throws {
        let key = Data(repeating: 7, count: 32)
        let codec = ProtectedCredentialCodec()
        let envelope = try codec.seal(password: "correct horse battery staple", using: key)

        XCTAssertNotEqual(envelope.ciphertext, Data("correct horse battery staple".utf8))
        XCTAssertEqual(try codec.open(envelope, using: key), "correct horse battery staple")
    }

    func testProtectedCredentialCodecRejectsWrongKey() throws {
        let codec = ProtectedCredentialCodec()
        let envelope = try codec.seal(password: "secret", using: Data(repeating: 1, count: 32))

        XCTAssertThrowsError(
            try codec.open(envelope, using: Data(repeating: 2, count: 32))
        )
    }

    func testUnlockAttemptGateFailsClosedAndAllowsOnlyOneAttempt() {
        var gate = UnlockAttemptGate()

        XCTAssertEqual(
            gate.authorize(
                locked: nil,
                sessionReady: true,
                accessibilityTrusted: true,
                password: "secret"
            ),
            .rejected("macOS did not provide a verifiable lock state. No password was entered.")
        )
        XCTAssertFalse(gate.hasAttempted)

        XCTAssertEqual(
            gate.authorize(
                locked: false,
                sessionReady: true,
                accessibilityTrusted: true,
                password: "secret"
            ),
            .rejected("The screen is not locked.")
        )
        XCTAssertEqual(
            gate.authorize(
                locked: true,
                sessionReady: true,
                accessibilityTrusted: false,
                password: "secret"
            ),
            .rejected("Accessibility permission is required.")
        )
        XCTAssertEqual(
            gate.authorize(
                locked: true,
                sessionReady: true,
                accessibilityTrusted: true,
                password: "secret"
            ),
            .entered
        )
        XCTAssertEqual(
            gate.authorize(
                locked: true,
                sessionReady: true,
                accessibilityTrusted: true,
                password: "secret"
            ),
            .rejected("Only one unlock attempt is allowed per lock session.")
        )
    }
}

private struct EmptyLockTestTemplateStore: FaceTemplateStoring {
    func load() throws -> UserFaceTemplate? { nil }
    func save(_ template: UserFaceTemplate) throws {}
}

private struct EmptyLockTestCredentialStore: ProtectedCredentialStoring {
    func hasStoredCredential() throws -> Bool { false }
    func save(password: String) throws -> ProtectedCredentialMaterial {
        throw ProtectedCredentialError.notConfigured
    }
    func loadAuthorizedMaterial() throws -> ProtectedCredentialMaterial {
        throw ProtectedCredentialError.notConfigured
    }
    func delete() throws {}
}
