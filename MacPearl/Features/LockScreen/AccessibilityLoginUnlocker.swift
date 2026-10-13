import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

enum LoginUnlockResult: Equatable, Sendable {
    case entered
    case rejected(String)
}

struct UnlockAttemptGate: Sendable {
    private(set) var hasAttempted = false

    mutating func authorize(
        locked: Bool?,
        sessionReady: Bool,
        accessibilityTrusted: Bool,
        password: String
    ) -> LoginUnlockResult {
        guard let locked else {
            return .rejected("macOS did not provide a verifiable lock state. No password was entered.")
        }
        guard locked else { return .rejected("The screen is not locked.") }
        guard sessionReady else { return .rejected("Automatic unlock is not armed.") }
        guard accessibilityTrusted else { return .rejected("Accessibility permission is required.") }
        guard !password.isEmpty else { return .rejected("No password is available.") }
        guard !hasAttempted else { return .rejected("Only one unlock attempt is allowed per lock session.") }
        hasAttempted = true
        return .entered
    }

    mutating func reset() {
        hasAttempted = false
    }
}

protocol LoginUnlocking: AnyObject {
    func unlock(password: String) async -> LoginUnlockResult
    func reset()
}

final class AccessibilityLoginUnlocker: LoginUnlocking {
    private var gate = UnlockAttemptGate()
    private let logger = Logger(subsystem: "com.stevenha.MacPearl", category: "lock-screen-unlock")

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func promptForPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func unlock(password: String) async -> LoginUnlockResult {
        let trusted = AXIsProcessTrusted()
        let locked = LockSessionMonitor.currentLockState()
        let lockDescription = locked.map { $0 ? "locked" : "unlocked" } ?? "unavailable"
        logger.info("Password-entry preflight: lockState=\(lockDescription, privacy: .public), accessibility=\(trusted)")
        let decision = gate.authorize(
            locked: locked,
            sessionReady: true,
            accessibilityTrusted: trusted,
            password: password
        )
        guard decision == .entered else { return decision }

        let worker = Task.detached(priority: .userInitiated) {
            Self.submit(password: password)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func submit(password: String) -> LoginUnlockResult {
        let source = CGEventSource(stateID: .hidSystemState)
        do {
            try requireLockedScreen()
            try clearFocusedField(source: source)
            let units = Array(password.utf16)
            var offset = 0
            while offset < units.count {
                try requireLockedScreen()
                var end = min(offset + 20, units.count)
                if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                    end -= 1
                }
                try postUnicode(Array(units[offset..<end]), source: source)
                offset = end
            }
            try requireLockedScreen()
            try postKey(36, source: source)
            return .entered
        } catch AccessibilityUnlockError.lockScreenDisappeared {
            return .rejected("The lock screen disappeared before password entry completed.")
        } catch {
            return .rejected("Could not submit keyboard events to the lock screen.")
        }
    }

    func reset() {
        gate.reset()
    }

    nonisolated private static func clearFocusedField(source: CGEventSource?) throws {
        try requireLockedScreen()
        try postKey(0x7C, flags: .maskCommand, source: source)
        try requireLockedScreen()
        try postKey(0x33, flags: .maskCommand, source: source)
    }

    nonisolated private static func postUnicode(_ characters: [UInt16], source: CGEventSource?) throws {
        try requireLockedScreen()
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw AccessibilityUnlockError.eventCreationFailed
        }
        characters.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.004)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.004)
    }

    nonisolated private static func postKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        source: CGEventSource?
    ) throws {
        try requireLockedScreen()
        let commandKey: CGKeyCode = 0x37
        let usesCommand = flags.contains(.maskCommand)
        if usesCommand {
            guard let commandDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: commandKey,
                keyDown: true
            ) else { throw AccessibilityUnlockError.eventCreationFailed }
            commandDown.flags = .maskCommand
            commandDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
        }

        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else { throw AccessibilityUnlockError.eventCreationFailed }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)

        if usesCommand {
            guard let commandUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: commandKey,
                keyDown: false
            ) else { throw AccessibilityUnlockError.eventCreationFailed }
            commandUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
        }
    }

    nonisolated private static func requireLockedScreen() throws {
        guard !Task.isCancelled, LockSessionMonitor.currentLockState() == true else {
            throw AccessibilityUnlockError.lockScreenDisappeared
        }
    }
}

private enum AccessibilityUnlockError: Error {
    case eventCreationFailed
    case lockScreenDisappeared
}
