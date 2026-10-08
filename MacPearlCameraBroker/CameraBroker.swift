import AppKit
import AVFoundation
import CommonCrypto
import Foundation
import OSLog

final class CameraBroker: NSObject, MacPearlCameraBrokerProtocol, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "com.stevenha.MacPearl.CameraBroker.capture")
    private let sampleQueue = DispatchQueue(label: "com.stevenha.MacPearl.CameraBroker.samples")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let logger = Logger(subsystem: "com.stevenha.MacPearl.CameraBroker", category: "capture")
    private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private var devices: [AVCaptureDevice] = []
    private var selectedDevice: AVCaptureDevice?
    private var startedAt: TimeInterval = 0
    private var latestFrameAt: TimeInterval?
    private var cancelledNonces = Set<Data>()
    private var notificationTokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        observeScreenState()
        observeCameraLifecycle()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func start() {
        switch authorizationStatus {
        case .authorized:
            queue.async { self.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.queue.async {
                    self.authorizationStatus = granted ? .authorized : .denied
                    if granted { self.configureAndStart() }
                    else { self.logger.error("Camera permission was denied") }
                }
            }
        default:
            logger.error("Camera permission unavailable: \(self.authorizationStatus.rawValue, privacy: .public)")
        }
    }

    func health(reply: @escaping (NSDictionary) -> Void) {
        queue.async { reply(self.currentResponse(nonce: Data())) }
    }

    func beginLockedScreenProbe(nonce: NSData, reply: @escaping (NSDictionary) -> Void) {
        let value = nonce as Data
        guard value.count == 32 else {
            reply(BrokerWire.response(outcome: .configurationFailed, authorizationStatus: authorizationStatus.rawValue))
            return
        }
        queue.async {
            if self.cancelledNonces.remove(value) != nil {
                reply(BrokerWire.response(outcome: .cancelled, authorizationStatus: self.authorizationStatus.rawValue, nonce: value))
                return
            }
            reply(self.currentResponse(nonce: value))
        }
    }

    func cancelProbe(nonce: NSData) {
        let value = nonce as Data
        queue.async { self.cancelledNonces.insert(value) }
    }

    private func configureAndStart() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        devices = discovery.devices.filter { $0.isConnected && !$0.isSuspended }
        selectedDevice = preferredDevice(in: devices)
        guard let selectedDevice else {
            logger.error("No usable camera")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: selectedDevice)
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                logger.error("Camera input or output could not be added")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            startedAt = ProcessInfo.processInfo.systemUptime
            session.startRunning()
            logger.info("Camera broker started device_type=\(selectedDevice.deviceType.rawValue, privacy: .public) device_hash=\(self.hash(selectedDevice.uniqueID), privacy: .public)")
        } catch {
            logger.error("Camera configuration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentResponse(nonce: Data) -> NSDictionary {
        let status = authorizationStatus.rawValue
        guard authorizationStatus == .authorized else {
            return BrokerWire.response(outcome: .permissionUnavailable, authorizationStatus: status, nonce: nonce)
        }
        guard let selectedDevice else {
            return BrokerWire.response(outcome: devices.isEmpty ? .noCamera : .configurationFailed, authorizationStatus: status, deviceCount: devices.count, nonce: nonce)
        }
        guard let latestFrameAt else {
            return BrokerWire.response(outcome: .timedOut, authorizationStatus: status, deviceCount: devices.count, deviceType: selectedDevice.deviceType.rawValue, deviceHash: hash(selectedDevice.uniqueID), nonce: nonce)
        }
        let age = ProcessInfo.processInfo.systemUptime - latestFrameAt
        return BrokerWire.response(
            outcome: age <= BrokerWire.maximumFrameAge ? .frameReceived : .staleFrame,
            authorizationStatus: status,
            deviceCount: devices.count,
            deviceType: selectedDevice.deviceType.rawValue,
            deviceHash: hash(selectedDevice.uniqueID),
            latencyMilliseconds: age * 1_000,
            nonce: nonce
        )
    }

    private func preferredDevice(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let preferred = AVCaptureDevice.systemPreferredCamera, devices.contains(where: { $0.uniqueID == preferred.uniqueID }) { return preferred }
        if let preferred = AVCaptureDevice.userPreferredCamera, devices.contains(where: { $0.uniqueID == preferred.uniqueID }) { return preferred }
        return devices.first(where: { $0.deviceType == .external })
            ?? devices.first(where: { $0.deviceType == .continuityCamera })
            ?? devices.first
    }

    private func hash(_ identifier: String) -> String {
        let data = Data(identifier.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func observeScreenState() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.logger.info("Screen locked; camera broker remains active")
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.logger.info("Screen unlocked")
        }
    }

    private func observeCameraLifecycle() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async {
                    guard let self, self.authorizationStatus == .authorized else { return }
                    self.latestFrameAt = nil
                    self.configureAndStart()
                }
            })
        }
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.configureAndStart() }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.logger.info("Camera broker session interrupted")
        })

        let workspace = NSWorkspace.shared.notificationCenter
        notificationTokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.latestFrameAt = nil
                if self.session.isRunning { self.session.stopRunning() }
                self.logger.info("Camera broker paused for sleep")
            }
        })
        notificationTokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async {
                guard let self, self.authorizationStatus == .authorized else { return }
                self.configureAndStart()
                self.logger.info("Camera broker restarted after wake")
            }
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let receivedAt = ProcessInfo.processInfo.systemUptime
        queue.async {
            if self.latestFrameAt == nil {
                self.logger.info("Camera broker received first frame in \((receivedAt - self.startedAt) * 1_000, privacy: .public) ms")
            }
            self.latestFrameAt = receivedAt
        }
    }
}
