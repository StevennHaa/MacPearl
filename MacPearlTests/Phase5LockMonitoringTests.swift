import XCTest
@testable import MacPearl

final class Phase5LockMonitoringTests: XCTestCase {
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
}
