//
//  CameraSessionController.swift
//  MacPearl
//

import AVFoundation
import Combine
import Foundation

enum CameraState: Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case unauthorized
    case unavailable
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            "Preparing camera…"
        case .requestingPermission:
            "Waiting for camera permission…"
        case .starting:
            "Starting camera…"
        case .running:
            "Camera ready"
        case .unauthorized:
            "Allow camera access in System Settings → Privacy & Security → Camera."
        case .unavailable:
            "No camera is available."
        case .failed(let message):
            message
        }
    }
}

final class CameraSessionController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var state: CameraState = .idle

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.stevenha.MacPearl.camera-session")
    private var currentInput: AVCaptureDeviceInput?
    private var deviceConnectionObservation: NSKeyValueObservation?
    private var deviceSuspensionObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var shouldRun = false

    override init() {
        super.init()
        observeCameraAvailability()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        shouldRun = true

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }

                    if granted && self.shouldRun {
                        self.configureAndStart()
                    } else {
                        self.state = .unauthorized
                    }
                }
            }
        case .denied, .restricted:
            state = .unauthorized
        @unknown default:
            state = .failed("The camera permission state is unknown.")
        }
    }

    func stop() {
        shouldRun = false

        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func configureAndStart() {
        guard shouldRun else { return }
        state = .starting

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                guard let camera = self.preferredUsableCamera() else {
                    self.transitionToUnavailable()
                    return
                }

                try self.configureSession(for: camera)

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                if self.session.isRunning && self.isUsable(camera) {
                    self.publish(.running)
                } else {
                    self.transitionToUnavailable()
                }
            } catch {
                self.publish(.failed("Couldn’t start the camera: \(error.localizedDescription)"))
            }
        }
    }

    private func configureSession(for camera: AVCaptureDevice) throws {
        if currentInput?.device.uniqueID == camera.uniqueID {
            return
        }

        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        if let currentInput {
            session.removeInput(currentInput)
        }

        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        session.addInput(input)
        currentInput = input
        observeAvailability(of: camera)
    }

    private func preferredUsableCamera() -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )

        let availableCameras = discoverySession.devices.filter(isUsable)

        if let systemPreferredCamera = AVCaptureDevice.systemPreferredCamera,
           availableCameras.contains(where: { $0.uniqueID == systemPreferredCamera.uniqueID }) {
            return systemPreferredCamera
        }

        if let userPreferredCamera = AVCaptureDevice.userPreferredCamera,
           availableCameras.contains(where: { $0.uniqueID == userPreferredCamera.uniqueID }) {
            return userPreferredCamera
        }

        return availableCameras.first(where: { $0.deviceType == .external })
            ?? availableCameras.first(where: { $0.deviceType == .continuityCamera })
            ?? availableCameras.first
    }

    private func isUsable(_ camera: AVCaptureDevice) -> Bool {
        camera.isConnected && !camera.isSuspended
    }

    private func transitionToUnavailable() {
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

    private func observeCameraAvailability() {
        let center = NotificationCenter.default

        notificationTokens = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.reevaluateCamera()
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.reevaluateCamera()
            },
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.reevaluateCamera()
            }
        ]
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
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.shouldRun,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                return
            }

            self.configureAndStart()
        }
    }

    private func publish(_ newState: CameraState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }
}

private enum CameraError: LocalizedError {
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            "The camera could not be added to the capture session."
        }
    }
}
