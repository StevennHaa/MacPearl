//
//  HomeView.swift
//  MacPearl
//
//  Created by Steven Ha on 9/29/26.
//

import SwiftUI

struct HomeView: View {
    @StateObject private var camera = CameraSessionController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MacPearl")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("Live camera preview")
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

                if camera.state == .running {
                    if camera.capturedFace != nil {
                        Button("Retake") { camera.retakeFace() }
                    } else if case .holding(let progress) = camera.faceCaptureState {
                        ProgressView(value: progress)
                            .frame(width: 100)
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    @ViewBuilder
    private var cameraStatus: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 36))

            Text(camera.state.message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if shouldOfferRetry {
                Button("Try Again") {
                    camera.start()
                }
            } else {
                ProgressView()
            }
        }
        .padding(24)
        .foregroundStyle(.white)
    }

    private var statusSymbol: String {
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
        case .unauthorized, .unavailable, .failed:
            true
        default:
            false
        }
    }

    private var statusMessage: String {
        guard camera.state == .running else { return camera.state.message }
        if camera.capturedFace != nil { return "Face captured — ready to continue" }
        switch camera.faceCaptureState {
        case .searching: return "Position your face in the camera"
        case .rejected(let issue): return issue.message
        case .holding: return "Hold still…"
        case .accepted: return "Face captured — ready to continue"
        }
    }

    private var statusColor: Color {
        guard camera.state == .running else { return .secondary }
        if camera.capturedFace != nil { return .green }
        if case .rejected = camera.faceCaptureState { return .orange }
        return .green
    }
}

#Preview {
    HomeView()
}
