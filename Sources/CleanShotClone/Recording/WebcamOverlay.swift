import AppKit
import AVFoundation

/// Floating webcam bubble shown during recording. It's a real on-screen window
/// inside the recorded region (deliberately NOT excluded from capture), so it is
/// baked into the recording — and the user can drag it anywhere mid-recording.
@MainActor
final class WebcamOverlay {
    private var panel: NSPanel?
    private var session: AVCaptureSession?

    func show(in regionGlobal: CGRect, shape: RecordingSettings.WebcamShape, size: RecordingSettings.WebcamSize) {
        guard panel == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Log.error("Webcam unavailable or not authorized", log: Log.recording)
            return
        }

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .high
        guard captureSession.canAddInput(input) else { return }
        captureSession.addInput(input)

        let edge = size.points
        let panelSize: NSSize = shape == .circle
            ? NSSize(width: edge, height: edge)
            : NSSize(width: edge, height: edge * 0.62)

        // Bottom-right corner of the recorded region, inset.
        let origin = NSPoint(
            x: regionGlobal.maxX - panelSize.width - 16,
            y: regionGlobal.minY + 16
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        let view = WebcamDragView(frame: NSRect(origin: .zero, size: panelSize))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = shape == .circle ? panelSize.width / 2 : 14
        preview.masksToBounds = true
        preview.borderWidth = 2
        preview.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        panel.contentView = view

        panel.orderFrontRegardless()
        self.panel = panel
        self.session = captureSession
        DispatchQueue.global(qos: .userInitiated).async { captureSession.startRunning() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        let s = session
        session = nil
        DispatchQueue.global(qos: .userInitiated).async { s?.stopRunning() }
    }
}

/// Drag anywhere on the bubble to reposition it while recording.
private final class WebcamDragView: NSView {
    private var dragStartGlobal: NSPoint = .zero
    private var baseOrigin: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartGlobal = NSEvent.mouseLocation
        baseOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let g = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: baseOrigin.x + (g.x - dragStartGlobal.x),
            y: baseOrigin.y + (g.y - dragStartGlobal.y)
        ))
    }
}
