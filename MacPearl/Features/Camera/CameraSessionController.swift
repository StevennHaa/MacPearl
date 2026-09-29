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
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            state = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }

                    if granted {
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
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func configureAndStart() {
        state = .starting

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                    self.isConfigured = true
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                }

                self.publish(.running)
            } catch CameraError.noCamera {
                self.publish(.unavailable)
            } catch {
                self.publish(.failed("Couldn’t start the camera: \(error.localizedDescription)"))
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .unspecified
        ) ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }

        session.addInput(input)
    }

    private func publish(_ newState: CameraState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .noCamera:
            "No camera was found."
        case .cannotAddInput:
            "The camera could not be added to the capture session."
        }
    }
}
