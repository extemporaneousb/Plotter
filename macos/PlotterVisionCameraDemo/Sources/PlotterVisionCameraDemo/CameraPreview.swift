import AVFoundation
import AppKit
import SwiftUI

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        if nsView.previewLayer.videoGravity != videoGravity {
            nsView.previewLayer.videoGravity = videoGravity
        }
    }
}

final class PreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        previewLayer.backgroundColor = NSColor.black.cgColor
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("PreviewView must be backed by AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    override func makeBackingLayer() -> CALayer {
        AVCaptureVideoPreviewLayer()
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

extension CameraPreviewMode {
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit:
            return .resizeAspect
        case .fill:
            return .resizeAspectFill
        }
    }
}
