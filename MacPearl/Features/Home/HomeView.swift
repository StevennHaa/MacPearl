//
//  HomeView.swift
//  MacPearl
//
//  Created by Steven Ha on 9/29/26.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var lockSessionMonitor: LockSessionMonitor
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginController
    @EnvironmentObject private var lockedSessionRecognition: LockedSessionRecognitionCoordinator
    @ObservedObject var camera: CameraSessionController
    @ObservedObject var recognition: RecognitionController
    @StateObject private var enrollment = EnrollmentController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MacPearl")
                    .font(.title)
                    .fontWeight(.semibold)
                Text(recognition.isActive ? "In-app lock demo" : "Live camera preview")
                    .foregroundStyle(.secondary)
            }

            ZStack {
                CameraPreviewView(
                    session: camera.session,
                    faces: camera.state == .running ? camera.faceDetectionResult.faces : [],
                    captureState: camera.faceCaptureState
                )
                .background(.black)

                if camera.state != .running {
                    cameraStatus
                } else if case .unlocked = recognition.state {
                    unlockedOverlay
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.quaternary, lineWidth: 1)
            }

            HStack {
                Label(statusMessage, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                Spacer()
                if camera.state == .running,
                   case .holding(let progress) = camera.faceCaptureState,
                   !recognition.isActive {
                    ProgressView(value: progress)
                        .frame(width: 100)
                }
            }

            primaryControls

            lockScreenFoundationControls

#if DEBUG
            if recognition.isActive {
                recognitionDiagnostics
            } else if enrollment.isActive {
                enrollmentDiagnostics
            }
#endif
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { lockedSessionRecognition.setPreviewVisible(true) }
        .onDisappear { lockedSessionRecognition.setPreviewVisible(false) }
        .onReceive(camera.$capturedFace) { frame in
            guard let frame else { return }
            if lockedSessionRecognition.isLockedSessionActive {
                return
            } else if recognition.isLocked {
                recognition.receive(frame, using: camera)
            } else {
                enrollment.receive(frame, using: camera)
            }
        }
        .onReceive(camera.$faceDetectionResult) { result in
            guard !lockedSessionRecognition.isLockedSessionActive else { return }
            recognition.updateFacePresence(!result.faces.isEmpty, using: camera)
        }
        .onReceive(enrollment.$state) { state in
            if case .enrolled = state {
                lockedSessionRecognition.refreshTemplate()
            }
        }
    }

    private var lockScreenFoundationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Launch MacPearl at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            Text(launchAtLogin.errorMessage ?? launchAtLogin.statusMessage)
                .font(.caption)
                .foregroundStyle(launchAtLogin.errorMessage == nil ? Color.secondary : Color.red)

            Label(
                lockedSessionRecognition.status.message,
                systemImage: lockedSessionRecognition.isLockedSessionActive
                    ? "person.crop.circle.badge.checkmark"
                    : "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

#if DEBUG
            HStack(spacing: 16) {
                Label(
                    lockSessionMonitor.snapshot.isLocked ? "Locked" : "Unlocked",
                    systemImage: lockSessionMonitor.snapshot.isLocked ? "lock.fill" : "lock.open.fill"
                )
                Text(lockSessionMonitor.snapshot.lastEvent.rawValue)
                Text("Events: \(lockSessionMonitor.snapshot.eventCount)")
                Text("Ready: \(lockSessionMonitor.snapshot.readyEventCount)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
#endif
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var primaryControls: some View {
        if recognition.isActive {
            recognitionControls
        } else {
            enrollmentControls
        }
    }

    @ViewBuilder
    private var recognitionControls: some View {
        HStack(spacing: 12) {
            switch recognition.state {
            case .idle:
                EmptyView()
            case .scanning(let matches, _):
                Label("Locked — verifying " + String(matches) + " of 3", systemImage: "lock.fill")
                Spacer()
                Button("Cancel Demo") { recognition.cancel(using: camera) }
            case .processing:
                ProgressView().controlSize(.small)
                Text("Comparing face…")
                Spacer()
                Button("Cancel Demo") { recognition.cancel(using: camera) }
            case .cooldown(let until):
                Label("Too many failed samples — pausing briefly", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Spacer()
                Text(until, style: .timer).monospacedDigit()
                Button("Cancel Demo") { recognition.cancel(using: camera) }
            case .unlocked:
                Label("Unlocked", systemImage: "lock.open.fill")
                    .foregroundStyle(.green)
                Spacer()
                if let template = enrollment.template {
                    Button("Lock Again") {
                        recognition.begin(template: template, using: camera)
                    }
                }
                Button("Exit Demo") { recognition.cancel(using: camera) }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                Spacer()
                Button("Exit Demo") { recognition.cancel(using: camera) }
            }
        }
    }

    @ViewBuilder
    private var enrollmentControls: some View {
        HStack(spacing: 12) {
            switch enrollment.state {
            case .idle:
                Button("Begin Enrollment") { enrollment.begin(using: camera) }
            case .capturing(let pose, let completed):
                Label("Step " + String(completed + 1) + " of 3: " + pose.instruction, systemImage: "person.badge.plus")
                Spacer()
                Button("Cancel") { enrollment.cancel(using: camera) }
            case .processing(_, let completed):
                ProgressView().controlSize(.small)
                Text("Processing sample " + String(completed + 1) + " of 3…")
                Spacer()
                Button("Cancel") { enrollment.cancel(using: camera) }
            case .enrolled(let template):
                Label("Local template ready (" + String(template.embeddings.count) + " poses)", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Lock Demo") {
                    recognition.begin(template: template, using: camera)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                Spacer()
                Button("Enroll Again") { enrollment.begin(using: camera) }
                Button("Cancel") { enrollment.cancel(using: camera) }
            }
        }
    }

#if DEBUG
    private var enrollmentDiagnostics: some View {
        let face = camera.faceDetectionResult.faces.first
        return HStack(spacing: 18) {
            Label("Development pose", systemImage: "viewfinder")
                .fontWeight(.medium)
            Text("Yaw: " + angleDescription(face?.yaw))
            Text("Pitch: " + angleDescription(face?.pitch))
            Text("Roll: " + angleDescription(face?.roll))
            Text("Quality: " + scoreDescription(face?.captureQuality))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var recognitionDiagnostics: some View {
        let diagnostics = recognition.diagnostics
        let score = diagnostics.score.map { String(format: "%.3f", $0) } ?? "—"
        let threshold = String(format: "%.2f", diagnostics.threshold)
        let latency = diagnostics.latencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        return HStack(spacing: 18) {
            Label("Development diagnostics", systemImage: "wrench.and.screwdriver")
                .fontWeight(.medium)
            Text("Score: " + score)
            Text("Threshold: " + threshold)
            Text("Window: " + String(diagnostics.matches) + "/" + String(diagnostics.samples))
            Text("Latency: " + latency)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func angleDescription(_ radians: Double?) -> String {
        guard let radians else { return "—" }
        return String(format: "%.1f°", radians * 180 / .pi)
    }

    private func scoreDescription(_ score: Float?) -> String {
        score.map { String(format: "%.2f", $0) } ?? "—"
    }
#endif

    private var unlockedOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 44))
            Text("MacPearl Unlocked")
                .font(.title2.bold())
        }
        .padding(28)
        .foregroundStyle(.white)
        .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var cameraStatus: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash").font(.system(size: 36))
            Text(camera.state.message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if shouldOfferRetry {
                Button("Try Again") { camera.start() }
            } else {
                ProgressView()
            }
        }
        .padding(24)
        .foregroundStyle(.white)
    }

    private var statusSymbol: String {
        if case .unlocked = recognition.state { return "lock.open.fill" }
        if recognition.isLocked { return "lock.fill" }
        guard camera.state == .running else { return "video" }
        switch camera.faceCaptureState {
        case .accepted: return "checkmark.circle.fill"
        case .rejected: return "exclamationmark.triangle"
        case .holding: return "person.crop.rectangle"
        case .searching: return "viewfinder"
        }
    }

    private var shouldOfferRetry: Bool {
        switch camera.state {
        case .unauthorized, .unavailable, .failed: true
        default: false
        }
    }

    private var statusMessage: String {
        guard camera.state == .running else { return camera.state.message }
        switch recognition.state {
        case .scanning:
            if camera.faceDetectionResult.faces.isEmpty {
                return "Position your face to unlock"
            }
            return recognition.diagnostics.score == nil
                ? "Face detected — hold still"
                : "Face detected — verifying identity"
        case .processing: return "Checking identity…"
        case .cooldown: return "Recognition paused briefly"
        case .unlocked: return "Stable match confirmed"
        case .failed(let message): return message
        case .idle: break
        }
        switch enrollment.state {
        case .capturing(let pose, _): return pose.instruction
        case .processing: return "Creating face embedding…"
        case .enrolled: return "Enrollment complete"
        case .failed(let message): return message
        case .idle: break
        }
        switch camera.faceCaptureState {
        case .searching: return "Position your face in the camera"
        case .rejected(let issue): return issue.message
        case .holding: return "Hold still…"
        case .accepted: return "Face captured — ready to continue"
        }
    }

    private var statusColor: Color {
        if case .unlocked = recognition.state { return .green }
        if case .cooldown = recognition.state { return .orange }
        guard camera.state == .running else { return .secondary }
        if case .rejected = camera.faceCaptureState { return .orange }
        return .green
    }
}

#Preview {
    let monitor = LockSessionMonitor()
    let coordinator = LockedSessionRecognitionCoordinator(lockSessionMonitor: monitor)
    HomeView(camera: coordinator.camera, recognition: coordinator.recognition)
        .environmentObject(monitor)
        .environmentObject(LaunchAtLoginController())
        .environmentObject(coordinator)
}
