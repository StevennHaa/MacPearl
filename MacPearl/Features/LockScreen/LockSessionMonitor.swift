import AppKit
import Combine
import CoreGraphics
import Foundation

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
    /// The recognition coordinator will consume this in the next PR.
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
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = session["CGSSessionScreenIsLocked"] as? Bool else {
            return nil
        }
        return locked
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
            MainActor.assumeIsolated { self?.process(.screenUnlocked) }
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

    private func scheduleSettledCheck(_ event: LockSessionEvent) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.process(event)
        }
    }

    private func process(_ event: LockSessionEvent) {
        let becameReady = reducer.receive(
            event,
            authoritativeLocked: lockStateProvider(),
            at: ProcessInfo.processInfo.systemUptime
        )
        snapshot = reducer.snapshot
        if becameReady { lockedSessionReadyGeneration += 1 }
    }
}
