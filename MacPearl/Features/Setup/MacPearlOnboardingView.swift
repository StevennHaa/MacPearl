import AppKit
import AVFoundation
import SwiftUI

struct MacPearlOnboardingView: View {
    @ObservedObject var session: AppSessionController
    @ObservedObject private var credentials: ProtectedCredentialController
    @ObservedObject private var enrollment: EnrollmentController
    @ObservedObject private var camera: CameraSessionController
    @State private var password = ""

    init(session: AppSessionController) {
        self.session = session
        credentials = session.credentials
        enrollment = session.enrollment
        camera = session.recognition.camera
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("MacPearl", systemImage: "faceid").foregroundStyle(.cyan)
                Spacer()
                Text(session.authorizationOnly ? "Authorize" : "Step \(session.step.rawValue + 1) of 5")
                    .foregroundStyle(.secondary)
            }
            Text(session.step.title).font(.largeTitle.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Later") { password = ""; session.closeSetup() }
                Spacer()
                if session.step != .welcome && !session.authorizationOnly {
                    Button("Back") { password = ""; session.back() }.disabled(credentials.isBusy)
                }
                if !session.authorizationOnly {
                    Button(session.step == .review ? "Finish Setup" : "Continue") { session.advance() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!session.canContinue || credentials.isBusy)
                }
            }
        }
        .padding(28)
        .onChange(of: session.passwordDraftGeneration) { _, _ in password = "" }
        .onDisappear { password = "" }
    }

    @ViewBuilder private var content: some View {
        switch session.step {
        case .welcome:
            Text("Look at your Mac to unlock your signed-in session.").font(.title2)
            Label("Face processing stays on your Mac.", systemImage: "lock.shield")
            Text("Your password is encrypted locally. Authorize once each time MacPearl opens; the session stays authorized until you quit.")
            Text("Camera-based recognition is not equivalent to Face ID or Touch ID. Keep your normal password available.").foregroundStyle(.secondary)
        case .permissions:
            permission("Camera", granted: session.cameraGranted, action: session.requestCamera)
            Text("Used to enroll and recognize your face locally.").foregroundStyle(.secondary)
            permission("Accessibility", granted: session.accessibilityGranted, action: session.requestAccessibility)
            Text("Used to submit your password only after a verified lock-screen match.").foregroundStyle(.secondary)
            if !session.cameraGranted || !session.accessibilityGranted {
                Text("After allowing access in System Settings, return here and click Check Permissions. When both permissions show a checkmark, click Continue.")
                    .font(.callout)
            }
            Button("Check Permissions") { session.refresh() }
        case .enrollment:
            if enrollment.isActive {
                CameraPreviewView(session: camera.session, faces: camera.faceDetectionResult.faces,
                                  captureState: camera.faceCaptureState, videoGravity: .resizeAspect,
                                  isMirrored: true)
                    .frame(height: 250).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            switch enrollment.state {
            case .capturing(let pose, let completed):
                enrollmentGuidance(pose: pose, completed: completed, processing: false)
            case .processing(let pose, let completed):
                enrollmentGuidance(pose: pose, completed: completed, processing: true)
            case .enrolled: Label("Your local face template is ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message): Text(message).foregroundStyle(.orange)
            case .idle: Text("Capture three poses in good light. Keep your face centered.")
            }
            if !session.hasFace && !enrollment.isActive { Button("Start Enrollment") { session.beginEnrollment() } }
        case .credential:
            if credentials.status == .sessionReady {
                Label("Password saved and automatic unlock authorized", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !session.authorizationOnly {
                    Text("Select Continue to finish setup. You don’t need to enter your password again.")
                }
            } else {
                Text("macOS will ask you to approve automatic unlock for this app session.")
                if credentials.needsRepair {
                    Text("Your saved unlock credential needs repair. Enter your current Mac password to rebuild it.")
                        .foregroundStyle(.orange)
                }
                if !credentials.hasStoredCredential || session.isUpdatingPassword {
                    SecureField("Mac login password", text: $password).textFieldStyle(.roundedBorder).disabled(credentials.isBusy)
                    Button(credentials.needsRepair ? "Verify and Repair" : "Verify, Save and Authorize") {
                        let draft = password
                        password = ""
                        credentials.save(password: draft)
                    }.disabled(password.isEmpty || credentials.isBusy)
                } else {
                    Button("Authorize Session") { session.requestAuthorization() }.disabled(credentials.isBusy)
                }
                if credentials.isBusy { ProgressView() }
                Text(credentials.status.message).foregroundStyle(.secondary)
                if credentials.hasStoredCredential && !session.isUpdatingPassword {
                    Button("Update Password…") { session.updatePassword() }.disabled(credentials.isBusy)
                }
                Text("Enter your current Mac login password. If you change it in macOS, update it here. Verification is performed only when you save or authorize—not repeatedly at the lock screen.").font(.caption).foregroundStyle(.secondary)
            }
        case .review:
            Label("Ready for your next locked session", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("After finishing, press Control–Command–Q and look at the camera. Your normal password remains available.")
            MacPearlPreferencesView(session: session)
        }
    }

    private func enrollmentGuidance(pose: FaceCapturePose, completed: Int, processing: Bool) -> some View {
        EnrollmentGuidanceView(pose: pose, completed: completed,
            guidance: .evaluate(pose: pose, faces: camera.faceDetectionResult.faces,
                                capture: camera.faceCaptureState, processing: processing))
    }

    private func permission(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
            Spacer()
            if !granted { Button("Allow", action: action) }
        }
    }
}
