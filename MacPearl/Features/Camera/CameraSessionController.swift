//
//  CameraSessionController.swift
//  MacPearl
//

import AppKit
import AVFoundation
import Combine
import Foundation

enum CameraState: Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case interrupted
    case recovering
    case unauthorized
    case unavailable
    case failed(String)

    var message: String {
        switch self {
        case .idle: "Preparing camera…"
        case .requestingPermission: "Waiting for camera permission…"
        case .starting: "Starting camera…"
        case .running: "Camera ready"
        case .interrupted: "Camera interrupted"
        case .recovering: "Recovering camera feed…"
        case .unauthorized:
            "Allow camera access in System Settings → Privacy & Security → Camera."
        case .unavailable: "No camera is available."
        case .failed(let message): message
        }
    }
}

final class CameraSessionController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var state: CameraState = .idle

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.stevenha.MacPearl.camera-session")
    private let sampleQueue = DispatchQueue(label: "com.stevenha.MacPearl.camera-samples")
    private let videoOutput = AVCaptureVideoDataOutput()

    private var currentInput: AVCaptureDeviceInput?
    private var deviceConnectionObservation: NSKeyValueObservation?
    private var deviceSuspensionObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var workspaceNotificationTokens: [NSObjectProtocol] = []

    // These properties are only read or written on sessionQueue.
    private var shouldRun = false
    private var isInterrupted = false
    private var isWaitingForFirstFrame = false
    private var lastFrameTime: DispatchTime?
    private var recoveryDeadline: DispatchTime?
    private var retryWorkItem: DispatchWorkItem?
    private var watchdogTimer: DispatchSourceTimer?

    private let recoveryTimeout: TimeInterval = 5
    private let retryDelay: TimeInterval = 0.75
    private let frameStallTimeout: TimeInterval = 3

    override init() {
        super.init()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        observeCameraAvailability()
        observeSessionLifecycle()
        observeSystemLifecycle()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        workspaceNotificationTokens.forEach(
            NSWorkspace.shared.notificationCenter.removeObserver
        )
        retryWorkItem?.cancel()
        watchdogTimer?.cancel()
    }

    func start() {
        sessionQueue.async { [weak self] in
            self?.shouldRun = true
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorizedCamera()
        case .notDetermined:
            publish(.requestingPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startAuthorizedCamera()
                } else {
                    self.publish(.unauthorized)
                }
            }
        case .denied, .restricted:
            publish(.unauthorized)
        @unknown default:
            publish(.failed("The camera permission state is unknown."))
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.resetRecoveryState()
            self.stopWatchdog()
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.publish(.idle)
        }
    }

    private func startAuthorizedCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.shouldRun else { return }
            self.isInterrupted = false
            self.beginAttempt(recovering: false)
        }
    }

    private func beginAttempt(recovering: Bool) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun, !isInterrupted else { return }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        recoveryDeadline = .now() + recoveryTimeout
        isWaitingForFirstFrame = false
        lastFrameTime = nil
        publish(recovering ? .recovering : .starting)
        startWatchdogIfNeeded()
        attemptToStartCamera()
    }

    private func attemptToStartCamera() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun, !isInterrupted else { return }

        guard let camera = preferredUsableCamera() else {
            CameraDiagnostics.noUsableCameraFound()
            scheduleRetryOrBecomeUnavailable()
            return
        }

        do {
            CameraDiagnostics.selectedDevice(camera)
            try configureSession(for: camera)

            // A full restart gives a stalled session a chance to produce frames again.
            if session.isRunning {
                session.stopRunning()
            }
            session.startRunning()

            guard session.isRunning, isUsable(camera) else {
                scheduleRetryOrBecomeUnavailable()
                return
            }

            isWaitingForFirstFrame = true
        } catch {
            CameraDiagnostics.configurationFailed(error)
            scheduleRetryOrBecomeUnavailable()
        }
    }

    private func configureSession(for camera: AVCaptureDevice) throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        if currentInput?.device.uniqueID != camera.uniqueID {
            let input = try AVCaptureDeviceInput(device: camera)
            let previousInput = currentInput

            if let previousInput {
                session.removeInput(previousInput)
                currentInput = nil
            }

            guard session.canAddInput(input) else {
                if let previousInput, session.canAddInput(previousInput) {
                    session.addInput(previousInput)
                    currentInput = previousInput
                }
                throw CameraError.cannotAddInput
            }

            session.addInput(input)
            currentInput = input
            observeAvailability(of: camera)
        }

        if !session.outputs.contains(where: { $0 === videoOutput }) {
            guard session.canAddOutput(videoOutput) else {
                throw CameraError.cannotAddOutput
            }
            session.addOutput(videoOutput)
        }
    }

    private func preferredUsableCamera() -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let availableCameras = discoverySession.devices.filter(isUsable)

        if let preferred = AVCaptureDevice.systemPreferredCamera,
           availableCameras.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            return preferred
        }

        if let preferred = AVCaptureDevice.userPreferredCamera,
           availableCameras.contains(where: { $0.uniqueID == preferred.uniqueID }) {
            return preferred
        }

        return availableCameras.first(where: { $0.deviceType == .external })
            ?? availableCameras.first(where: { $0.deviceType == .continuityCamera })
            ?? availableCameras.first
    }

    private func isUsable(_ camera: AVCaptureDevice) -> Bool {
        camera.isConnected && !camera.isSuspended
    }

    private func startRecovery() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun, !isInterrupted else { return }
        beginAttempt(recovering: true)
    }

    private func scheduleRetryOrBecomeUnavailable() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun, !isInterrupted else { return }

        if let deadline = recoveryDeadline, DispatchTime.now() < deadline {
            CameraDiagnostics.retryScheduled()
            retryWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.attemptToStartCamera()
            }
            retryWorkItem = workItem
            sessionQueue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
        } else {
            CameraDiagnostics.recoveryTimedOut()
            transitionToUnavailable()
        }
    }

    private func transitionToUnavailable() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        resetRecoveryState()
        stopWatchdog()
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        session.commitConfiguration()

        currentInput = nil
        deviceConnectionObservation = nil
        deviceSuspensionObservation = nil
        publish(.unavailable)
    }

    private func startWatchdogIfNeeded() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard watchdogTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.checkCameraHealth()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func checkCameraHealth() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun, !isInterrupted else { return }

        let now = DispatchTime.now()
        if isWaitingForFirstFrame {
            if let deadline = recoveryDeadline, now >= deadline {
                CameraDiagnostics.recoveryTimedOut()
                transitionToUnavailable()
            }
            return
        }

        guard let lastFrameTime else { return }
        let elapsed = Double(now.uptimeNanoseconds - lastFrameTime.uptimeNanoseconds) / 1_000_000_000
        if elapsed >= frameStallTimeout {
            CameraDiagnostics.frameStalled(elapsed: elapsed)
            startRecovery()
        }
    }

    private func receivedVideoFrame() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun, !isInterrupted else { return }

        lastFrameTime = .now()
        guard isWaitingForFirstFrame else { return }

        isWaitingForFirstFrame = false
        recoveryDeadline = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        publish(.running)
    }

    private func resetRecoveryState() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        retryWorkItem?.cancel()
        retryWorkItem = nil
        recoveryDeadline = nil
        isWaitingForFirstFrame = false
        lastFrameTime = nil
    }

    private func observeCameraAvailability() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.reevaluateCamera() }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in self?.reevaluateCamera() }
        )
    }

    private func observeAvailability(of camera: AVCaptureDevice) {
        deviceConnectionObservation = camera.observe(\.isConnected, options: [.new]) { [weak self] _, _ in
            self?.reevaluateCamera()
        }
        deviceSuspensionObservation = camera.observe(\.isSuspended, options: [.new]) { [weak self] _, _ in
            self?.reevaluateCamera()
        }
    }

    private func reevaluateCamera() {
        CameraDiagnostics.cameraAvailabilityChanged()
        sessionQueue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            self.startRecovery()
        }
    }

    private func observeSessionLifecycle() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { self?.handleSessionInterrupted() }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { self?.handleInterruptionEnded() }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                self?.sessionQueue.async {
                    self?.handleRuntimeError(notification)
                }
            }
        )
    }

    private func observeSystemLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceNotificationTokens.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { self?.handleSystemSleep() }
            }
        )
        workspaceNotificationTokens.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { self?.handleSystemWake() }
            }
        )
    }

    private func handleSessionInterrupted() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun else { return }
        CameraDiagnostics.sessionInterrupted()
        isInterrupted = true
        resetRecoveryState()
        recoveryDeadline = .now() + recoveryTimeout
        publish(.interrupted)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun, self.isInterrupted else { return }
            CameraDiagnostics.recoveryTimedOut()
            self.transitionToUnavailable()
        }
        retryWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + recoveryTimeout, execute: workItem)
    }

    private func handleInterruptionEnded() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun else { return }
        CameraDiagnostics.interruptionEnded()
        isInterrupted = false
        startRecovery()
    }

    private func handleRuntimeError(_ notification: Notification) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun else { return }
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        CameraDiagnostics.runtimeError(error)
        isInterrupted = false
        startRecovery()
    }

    private func handleSystemSleep() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun else { return }
        CameraDiagnostics.systemWillSleep()
        isInterrupted = true
        resetRecoveryState()
        publish(.interrupted)
    }

    private func handleSystemWake() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard shouldRun else { return }
        CameraDiagnostics.systemDidWake()
        isInterrupted = false
        startRecovery()
    }

    private func publish(_ newState: CameraState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            CameraDiagnostics.stateTransition(from: self.state, to: newState)
            self.state = newState
        }
    }
}

extension CameraSessionController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sessionQueue.async { [weak self] in
            self?.receivedVideoFrame()
        }
    }
}

private enum CameraError: LocalizedError {
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: "The camera could not be added to the capture session."
        case .cannotAddOutput: "The camera could not provide video frames."
        }
    }
}
