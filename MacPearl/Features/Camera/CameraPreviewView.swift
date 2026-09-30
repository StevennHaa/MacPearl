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

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session, faces: faces)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.session = session
        nsView.faces = faces
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let faceOverlayLayer = CAShapeLayer()

    var faces: [DetectedFace] = [] {
        didSet { updateFaceOverlay() }
    }

    var session: AVCaptureSession? {
        get { previewLayer.session }
        set { previewLayer.session = newValue }
    }

    init(session: AVCaptureSession, faces: [DetectedFace]) {
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
}
