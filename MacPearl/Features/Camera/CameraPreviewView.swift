//
//  CameraPreviewView.swift
//  MacPearl
//

import AppKit
import AVFoundation
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let faces: [DetectedFace]
    let captureState: FaceCaptureState
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(session: session, faces: faces, captureState: captureState)
        view.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.session = session
        nsView.faces = faces
        nsView.captureState = captureState
        nsView.videoGravity = videoGravity
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let faceOverlayLayer = CAShapeLayer()

    var videoGravity: AVLayerVideoGravity {
        get { previewLayer.videoGravity }
        set { previewLayer.videoGravity = newValue }
    }

    var faces: [DetectedFace] = [] {
        didSet { updateFaceOverlay() }
    }

    var captureState: FaceCaptureState = .searching {
        didSet { updateOverlayColor() }
    }

    var session: AVCaptureSession? {
        get { previewLayer.session }
        set { previewLayer.session = newValue }
    }

    init(session: AVCaptureSession, faces: [DetectedFace], captureState: FaceCaptureState) {
        super.init(frame: .zero)

        wantsLayer = true
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)

        faceOverlayLayer.fillColor = NSColor.clear.cgColor
        faceOverlayLayer.strokeColor = NSColor.systemGreen.cgColor
        faceOverlayLayer.lineWidth = 2
        faceOverlayLayer.masksToBounds = true
        layer?.addSublayer(faceOverlayLayer)
        self.faces = faces
        self.captureState = captureState
        updateOverlayColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        faceOverlayLayer.frame = bounds
        updateFaceOverlay()
        CATransaction.commit()
    }

    private func updateFaceOverlay() {
        let path = CGMutablePath()

        for face in faces {
            let box = face.boundingBox
            // Vision uses a lower-left origin; metadata coordinates use upper-left.
            let metadataRect = CGRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            let previewRect = previewLayer.layerRectConverted(
                fromMetadataOutputRect: metadataRect
            )
            // On macOS, the preview conversion and shape path render with opposite
            // vertical axes. Reflect the converted box into the overlay's axis.
            let overlayRect = CGRect(
                x: previewRect.minX,
                y: faceOverlayLayer.bounds.height - previewRect.maxY,
                width: previewRect.width,
                height: previewRect.height
            )
            path.addRect(overlayRect)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faceOverlayLayer.path = path
        CATransaction.commit()
    }

    private func updateOverlayColor() {
        let color: NSColor
        switch captureState {
        case .accepted, .holding: color = .systemGreen
        case .rejected: color = .systemOrange
        case .searching: color = .systemYellow
        }
        faceOverlayLayer.strokeColor = color.cgColor
    }
}
