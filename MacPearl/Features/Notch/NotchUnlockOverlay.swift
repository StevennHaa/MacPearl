import AppKit
import Combine
import SwiftUI

enum NotchUnlockPhase: Equatable {
    case hidden
    case scanning
    case recognized
    case success
    case attention(String)
}

struct NotchUnlockPresentation {
    private var confirmedUnlockCount = 0
    private var wasEnteringPassword = false

    mutating func update(
        snapshot: LockSessionSnapshot,
        status: LockedSessionRecognitionStatus,
        camera: CameraState,
        active: Bool
    ) -> NotchUnlockPhase {
        if snapshot.confirmedUnlockCount > confirmedUnlockCount {
            confirmedUnlockCount = snapshot.confirmedUnlockCount
            let result: NotchUnlockPhase = wasEnteringPassword ? .success : .hidden
            wasEnteringPassword = false
            return result
        }
        guard snapshot.isLocked, !snapshot.isSleeping else {
            wasEnteringPassword = false
            return .hidden
        }
        // Coordinator teardown may publish inactive/idle before this subscriber
        // receives the new confirmed-unlock snapshot. Preserve the match latch
        // through those intermediate publications.
        guard active else { return .hidden }
        switch status {
        case .unlocking:
            wasEnteringPassword = true
            return .recognized
        case .recognized:
            wasEnteringPassword = false
            return .attention("Authorize in MacPearl")
        case .unlockFailed, .failed, .cooldown:
            wasEnteringPassword = false
            return .attention("Use your password")
        default:
            break
        }
        switch camera {
        case .unauthorized, .unavailable, .failed:
            return .attention("Camera unavailable")
        default:
            return .scanning
        }
    }
}

struct NotchOverlayGeometry: Equatable {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    static func forScreen(_ screen: NSScreen) -> Self {
        let hasNotch = screen.safeAreaInsets.top > 0
        let width = screen.frame.width
            - (screen.auxiliaryTopLeftArea?.width ?? 0)
            - (screen.auxiliaryTopRightArea?.width ?? 0)
        return Self(
            notchWidth: hasNotch ? min(max(width, 180), 320) : 100,
            notchHeight: hasNotch ? screen.safeAreaInsets.top : 0,
            hasNotch: hasNotch
        )
    }
}

@MainActor
final class NotchUnlockOverlayController: ObservableObject {
    @Published private(set) var phase: NotchUnlockPhase = .hidden
    @Published private(set) var geometry = NotchOverlayGeometry(notchWidth: 180, notchHeight: 32, hasNotch: true)

    private var presentation = NotchUnlockPresentation()
    private var subscriptions = Set<AnyCancellable>()
    private var panel: NotchUnlockPanel?
    private var lockSpace: LockScreenOverlaySpace?
    private var delegated = false
    private var attemptedLockSpaceCreation = false
    private var dismissTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var latest: (LockSessionSnapshot, LockedSessionRecognitionStatus, CameraState, Bool)?

    init(monitor: LockSessionMonitor, recognition: LockedSessionRecognitionCoordinator) {
        recognition.$status
            .combineLatest(recognition.camera.$state, monitor.$snapshot, recognition.$isLockedSessionActive)
            .sink { [weak self] status, camera, snapshot, active in
                guard let self else { return }
                self.latest = (snapshot, status, camera, active)
                self.render(snapshot: snapshot, status: status, camera: camera, active: active)
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .sink { [weak self] _ in
                guard let self, let (snapshot, status, camera, active) = self.latest else { return }
                self.render(snapshot: snapshot, status: status, camera: camera, active: active)
            }
            .store(in: &subscriptions)
    }

    private func render(snapshot: LockSessionSnapshot, status: LockedSessionRecognitionStatus, camera: CameraState, active: Bool) {
        let next = presentation.update(snapshot: snapshot, status: status, camera: camera, active: active)
        let enabled = UserDefaults.standard.object(forKey: "showNotchAnimation") as? Bool ?? true
        guard enabled else { previewTask?.cancel(); previewTask = nil; hide(immediately: true); return }
        if previewTask != nil {
            if !snapshot.isLocked { return }
            previewTask?.cancel()
            previewTask = nil
        }
        if !snapshot.isLocked { removeLockScreenDelegation() }
        // Keep the confirmed-unlock animation alive across the subsequent
        // idle/camera-stop publications, without delaying the actual unlock.
        if phase == .success, next == .hidden, !snapshot.isLocked, dismissTask != nil { return }
        guard next != .hidden else { hide(); return }
        if phase != next { dismissTask?.cancel(); dismissTask = nil }
        show(phase: next, locked: snapshot.isLocked)
        if next == .success, dismissTask == nil {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1100))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        } else if case .attention = next, dismissTask == nil {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func preview() {
        guard latest?.0.isLocked == false else { return }
        previewTask?.cancel()
        dismissTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            self.show(phase: .scanning, locked: false)
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.show(phase: .recognized, locked: false)
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.show(phase: .success, locked: false)
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self.previewTask = nil
            self.hide()
        }
    }

    private func show(phase next: NotchUnlockPhase, locked: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        geometry = .forScreen(screen)
        if panel == nil {
            let window = NotchUnlockPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: NotchUnlockOverlayView(controller: self))
            panel = window
        }
        guard let panel else { return }
        let top = geometry.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: top - panel.frame.height))
        // Render the compact footprint before expanding on the next run loop.
        if !panel.isVisible {
            self.phase = .hidden
            panel.orderFrontRegardless()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        if locked, LockSessionMonitor.currentLockState() == true, !delegated {
            if !attemptedLockSpaceCreation {
                attemptedLockSpaceCreation = true
                lockSpace = LockScreenOverlaySpace()
            }
            delegated = lockSpace?.attach(panel) ?? false
        }
        self.phase = next
    }

    private func removeLockScreenDelegation() {
        if delegated, let panel { lockSpace?.detach(panel) }
        delegated = false
    }

    private func hide(immediately: Bool = false) {
        dismissTask?.cancel()
        dismissTask = nil
        if phase == .hidden, hideTask != nil, !immediately { return }
        phase = .hidden
        removeLockScreenDelegation()
        hideTask?.cancel()
        if immediately {
            panel?.orderOut(nil)
            hideTask = nil
        } else {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
                self?.hideTask = nil
            }
        }
    }
}

private final class NotchUnlockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct NotchUnlockOverlayView: View {
    @ObservedObject var controller: NotchUnlockOverlayController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { controller.phase != .hidden }
    private var tint: Color {
        switch controller.phase {
        case .success: .green
        case .attention: .orange
        default: .cyan
        }
    }
    private var title: String {
        switch controller.phase {
        case .scanning: "Looking for you"
        case .recognized: "Unlocking…"
        case .success: "Unlocked"
        case .attention(let message): message
        case .hidden: "MacPearl"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: controller.geometry.hasNotch ? controller.geometry.notchHeight : 12)
            if expanded {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(tint)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && controller.phase == .scanning)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.10), value: controller.phase)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text("MacPearl").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    if controller.phase == .scanning || controller.phase == .recognized {
                        ProgressView().controlSize(.small).tint(tint)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
        .frame(width: expanded ? max(280, controller.geometry.notchWidth + 50) : controller.geometry.notchWidth)
        .background(.black, in: UnevenRoundedRectangle(
            topLeadingRadius: controller.geometry.hasNotch ? 8 : 26,
            bottomLeadingRadius: 26, bottomTrailingRadius: 26,
            topTrailingRadius: controller.geometry.hasNotch ? 8 : 26
        ))
        .overlay(alignment: .bottom) {
            if controller.phase == .scanning {
                Capsule().fill(tint.opacity(0.75)).frame(width: 42, height: 2).padding(.bottom, 7)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.18, dampingFraction: 0.86), value: controller.phase)
        .frame(width: 380, height: 160, alignment: .top)
        .accessibilityLabel("MacPearl: \(title)")
    }

    private var symbol: String {
        switch controller.phase {
        case .scanning: "faceid"
        case .recognized: "lock.open.fill"
        case .success: "lock.open.fill"
        case .attention: "exclamationmark.circle"
        case .hidden: "camera"
        }
    }
}
