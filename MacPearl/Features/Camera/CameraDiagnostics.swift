//
//  CameraDiagnostics.swift
//  MacPearl
//

import AVFoundation
import Foundation
import OSLog

enum CameraDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.stevenha.MacPearl",
        category: "Camera"
    )

    static func stateTransition(from oldState: CameraState, to newState: CameraState) {
        guard oldState != newState else { return }
        logger.info(
            "State changed: \(oldState.diagnosticName, privacy: .public) -> \(newState.diagnosticName, privacy: .public)"
        )
    }

    static func selectedDevice(_ device: AVCaptureDevice) {
        logger.info(
            "Selected camera type=\(device.deviceType.rawValue, privacy: .public) id=\(device.uniqueID, privacy: .private(mask: .hash))"
        )
    }

    static func noUsableCameraFound() {
        logger.warning("No usable camera was found")
    }

    static func retryScheduled() {
        logger.notice("Camera start failed; scheduling a bounded retry")
    }

    static func recoveryTimedOut() {
        logger.error("Camera recovery timed out; transitioning to unavailable")
    }

    static func configurationFailed(_ error: Error) {
        logger.error(
            "Camera configuration failed: \(error.localizedDescription, privacy: .private)"
        )
    }

    static func frameStalled(elapsed: TimeInterval) {
        logger.error(
            "Camera stopped producing frames for \(elapsed, format: .fixed(precision: 1), privacy: .public) seconds"
        )
    }

    static func faceDetectionFailed(_ error: Error) {
        logger.error(
            "Face detection failed: \(error.localizedDescription, privacy: .private)"
        )
    }

    static func sessionInterrupted() {
        logger.notice("Capture session interrupted")
    }

    static func interruptionEnded() {
        logger.notice("Capture session interruption ended")
    }

    static func runtimeError(_ error: AVError?) {
        guard let error else {
            logger.error("Capture session reported an unknown runtime error")
            return
        }

        logger.error(
            "Capture session runtime error code=\(error.code.rawValue, privacy: .public) description=\(error.localizedDescription, privacy: .private)"
        )
    }

    static func systemWillSleep() {
        logger.notice("System will sleep; camera marked interrupted")
    }

    static func systemDidWake() {
        logger.notice("System woke; beginning camera recovery")
    }

    static func cameraAvailabilityChanged() {
        logger.notice("Camera hardware availability changed; reevaluating devices")
    }
}

private extension CameraState {
    var diagnosticName: String {
        switch self {
        case .idle: "idle"
        case .requestingPermission: "requestingPermission"
        case .starting: "starting"
        case .running: "running"
        case .interrupted: "interrupted"
        case .recovering: "recovering"
        case .unauthorized: "unauthorized"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }
}
