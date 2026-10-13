import XCTest
@testable import MacPearl

@MainActor
final class NotchUnlockOverlayTests: XCTestCase {
    func testCoordinatorTeardownBeforeUnlockPublicationPreservesSuccess() {
        var presentation = NotchUnlockPresentation()
        let locked = LockSessionSnapshot(isLocked: true)
        _ = presentation.update(snapshot: locked, status: .unlocking, camera: .running, active: true)
        XCTAssertEqual(presentation.update(snapshot: locked, status: .ready, camera: .idle, active: false), .hidden)
        XCTAssertEqual(presentation.update(snapshot: LockSessionSnapshot(confirmedUnlockCount: 1), status: .ready, camera: .idle, active: false), .success)
    }

    func testScanningAndMatchedStatesDoNotClaimUnlock() {
        var presentation = NotchUnlockPresentation()
        let locked = LockSessionSnapshot(isLocked: true)
        XCTAssertEqual(presentation.update(snapshot: locked, status: .scanning(matches: 1, samples: 1), camera: .running, active: true), .scanning)
        XCTAssertEqual(presentation.update(snapshot: locked, status: .unlocking, camera: .running, active: true), .recognized)
        XCTAssertEqual(presentation.update(snapshot: locked, status: .unlocking, camera: .running, active: true), .recognized)
        XCTAssertEqual(presentation.update(snapshot: LockSessionSnapshot(confirmedUnlockCount: 1), status: .unlocking, camera: .running, active: true), .success)
    }

    func testManualUnlockWithoutMatchDoesNotShowSuccess() {
        var presentation = NotchUnlockPresentation()
        _ = presentation.update(snapshot: LockSessionSnapshot(isLocked: true), status: .scanning(matches: 0, samples: 0), camera: .running, active: true)
        XCTAssertEqual(presentation.update(snapshot: LockSessionSnapshot(confirmedUnlockCount: 1), status: .scanning(matches: 0, samples: 0), camera: .running, active: false), .hidden)
    }

    func testUnknownStateAndSleepHideOverlayWithoutSuccess() {
        var presentation = NotchUnlockPresentation()
        _ = presentation.update(snapshot: LockSessionSnapshot(isLocked: true), status: .unlocking, camera: .running, active: true)
        XCTAssertEqual(presentation.update(snapshot: LockSessionSnapshot(isLocked: true, isSleeping: true), status: .sleeping, camera: .idle, active: false), .hidden)
        XCTAssertEqual(presentation.update(snapshot: LockSessionSnapshot(confirmedUnlockCount: 1), status: .ready, camera: .idle, active: false), .hidden)
    }

    func testUnarmedAndFailedAttemptsShowAttentionNotSuccess() {
        var presentation = NotchUnlockPresentation()
        let locked = LockSessionSnapshot(isLocked: true)
        XCTAssertEqual(presentation.update(snapshot: locked, status: .recognized(score: 0.8), camera: .running, active: true), .attention("Authorize in MacPearl"))
        _ = presentation.update(snapshot: locked, status: .unlocking, camera: .running, active: true)
        XCTAssertEqual(presentation.update(snapshot: locked, status: .unlockFailed("Failed"), camera: .running, active: true), .attention("Use your password"))
        XCTAssertEqual(presentation.update(snapshot: LockSessionSnapshot(confirmedUnlockCount: 1), status: .ready, camera: .idle, active: false), .hidden)
    }

    func testUnavailableCameraGetsAnExplanation() {
        var presentation = NotchUnlockPresentation()
        XCTAssertEqual(presentation.update(snapshot: LockSessionSnapshot(isLocked: true), status: .ready, camera: .unavailable, active: true), .attention("Camera unavailable"))
    }
}
