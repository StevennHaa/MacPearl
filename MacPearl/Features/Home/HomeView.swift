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
                CameraPreviewView(session: camera.session)
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
                Label(camera.state.message, systemImage: statusSymbol)
                    .foregroundStyle(camera.state == .running ? .green : .secondary)

                Spacer()

                if camera.state == .running {
                    Label(faceDetectionMessage, systemImage: "person.crop.rectangle")
                        .foregroundStyle(.secondary)
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
        camera.state == .running ? "checkmark.circle.fill" : "video"
    }

    private var shouldOfferRetry: Bool {
        switch camera.state {
        case .unauthorized, .unavailable, .failed:
            true
        default:
            false
        }
    }

    private var faceDetectionMessage: String {
        if camera.faceDetectionResult.errorDescription != nil {
            return "Detection unavailable"
        }

        let count = camera.faceDetectionResult.faces.count
        return count == 1 ? "1 face" : "\(count) faces"
    }
}

#Preview {
    HomeView()
}
