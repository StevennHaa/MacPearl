import AppKit
import Combine
import CoreGraphics
import Foundation
import IOKit

struct ConsoleLockStateResolver: Sendable {
    nonisolated static func resolve(
        consoleUsers: [[String: Any]],
        consoleLocked: Bool?,
        userID: UInt32,
        quartzLocked: Bool? = nil
    ) -> Bool? {
        let activeUsers = consoleUsers.filter {
            ($0["kCGSSessionOnConsoleKey"] as? Bool) == true
        }
        guard activeUsers.count == 1,
              let session = activeUsers.first,
              (session["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == userID,
              (session["kCGSessionLoginDoneKey"] as? Bool) == true else {
            return nil
        }
        let sessionLocked = session["CGSSessionScreenIsLocked"] as? Bool
        if let sessionLocked, let consoleLocked, sessionLocked != consoleLocked {
            return nil
        }
        let registryLocked = consoleLocked ?? sessionLocked
        if let quartzLocked, let registryLocked, quartzLocked != registryLocked {
            return nil
        }
        return quartzLocked ?? registryLocked
    }
}

enum LockSessionEvent: String, Equatable, Sendable {
    case initialCheck = "Initial check"
    case screenLocked = "Screen locked"
    case screenUnlocked = "Screen unlocked"
    case screensDidWake = "Displays woke"
    case systemDidWake = "System woke"
    case willSleep = "System sleeping"
}

struct LockSessionSnapshot: Equatable, Sendable {
    var isLocked = false
    var isSleeping = false
    var lastEvent: LockSessionEvent = .initialCheck
    var eventCount = 0
    var readyEventCount = 0
    var confirmedUnlockCount = 0
}

struct LockSessionEventReducer: Sendable {
    static let defaultDebounceInterval: TimeInterval = 2

    private(set) var snapshot = LockSessionSnapshot()
    private var lastReadyEventAt: TimeInterval?
    let debounceInterval: TimeInterval

    init(debounceInterval: TimeInterval = Self.defaultDebounceInterval) {
        self.debounceInterval = debounceInterval
    }

    @discardableResult
    mutating func receive(
        _ event: LockSessionEvent,
        authoritativeLocked: Bool?,
        at timestamp: TimeInterval
    ) -> Bool {
        snapshot.lastEvent = event
        snapshot.eventCount += 1
        if event == .screenUnlocked, authoritativeLocked == false {
            snapshot.confirmedUnlockCount += 1
        }

        switch event {
        case .willSleep:
            snapshot.isSleeping = true
        case .screensDidWake, .systemDidWake:
            snapshot.isSleeping = false
        case .initialCheck, .screenLocked, .screenUnlocked:
            break
        }

        // Unknown CoreGraphics state always fails closed. Distributed
        // notifications are triggers, never proof that the screen is locked.
        snapshot.isLocked = authoritativeLocked ?? false
        guard snapshot.isLocked, !snapshot.isSleeping else {
            if !snapshot.isLocked { lastReadyEventAt = nil }
            return false
        }

        if let lastReadyEventAt,
           timestamp - lastReadyEventAt < debounceInterval {
            return false
        }
        lastReadyEventAt = timestamp
        snapshot.readyEventCount += 1
        return true
    }
}

@MainActor
final class LockSessionMonitor: ObservableObject {
    @Published private(set) var snapshot = LockSessionSnapshot()

    /// Incremented only after an authoritative locked-state check succeeds.
    /// LockedSessionRecognitionCoordinator consumes each generation once.
    @Published private(set) var lockedSessionReadyGeneration = 0

    private var reducer = LockSessionEventReducer()
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private let lockStateProvider: @MainActor () -> Bool?

    init(lockStateProvider: @escaping @MainActor () -> Bool? = LockSessionMonitor.currentLockState) {
        self.lockStateProvider = lockStateProvider
        installObservers()
        process(.initialCheck)
    }

    deinit {
        refreshTask?.cancel()
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributed.removeObserver)
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspace.removeObserver)
    }

    nonisolated static func currentLockState() -> Bool? {
        let quartz = CGSessionCopyCurrentDictionary() as? [String: Any]
        // The Quartz session dictionary can omit the lock flag while the
        // login window is active. Use kernel-published console state instead;
        // never infer a locked screen from a distributed notification.
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(root, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any],
              let consoleUsers = values["IOConsoleUsers"] as? [[String: Any]] else {
            return nil
        }
        return ConsoleLockStateResolver.resolve(
            consoleUsers: consoleUsers,
            consoleLocked: values["IOConsoleLocked"] as? Bool,
            userID: getuid(),
            quartzLocked: quartz?["CGSSessionScreenIsLocked"] as? Bool
        )
    }

    private func installObservers() {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettledCheck(.screenLocked) }
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTask?.cancel()
                self?.scheduleSettledCheck(.screenUnlocked)
            }
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettledCheck(.screensDidWake) }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.process(.willSleep) }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettledCheck(.systemDidWake) }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettledCheck(.screensDidWake) }
        })
    }

    func scheduleSettledCheck(_ event: LockSessionEvent) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // Lock notifications can precede the console lock flag. A single
            // failed lookup previously left recognition idle until display wake.
            for attempt in 0..<12 {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                let locked = self.lockStateProvider()
                let expectedLocked = event != .screenUnlocked
                if locked == expectedLocked {
                    self.process(event, authoritativeLocked: expectedLocked)
                    return
                }
                if attempt == 11 {
                    // An uncertain probe may stop scanning, but cannot reset
                    // the password budget as a confirmed unlock.
                    self.process(event, authoritativeLocked: locked, useProvidedState: true)
                }
            }
        }
    }

    private func process(
        _ event: LockSessionEvent,
        authoritativeLocked: Bool? = nil,
        useProvidedState: Bool = false
    ) {
        let becameReady = reducer.receive(
            event,
            authoritativeLocked: useProvidedState ? authoritativeLocked : (authoritativeLocked ?? lockStateProvider()),
            at: ProcessInfo.processInfo.systemUptime
        )
        snapshot = reducer.snapshot
        if becameReady { lockedSessionReadyGeneration += 1 }
    }
}
