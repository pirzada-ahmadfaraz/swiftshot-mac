import AppKit
import ScreenCaptureKit

/// Lets the user click a window to capture it. Overlays each screen and highlights the window under the cursor.
final class WindowPickerController {
    private var panels: [OverlayPanel] = []
    private var completion: ((CGWindowID?) -> Void)?

    func start(completion: @escaping (CGWindowID?) -> Void) {
        guard panels.isEmpty else { return }
        self.completion = completion

        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, screen: screen)
            let view = WindowHoverView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
            view.onPick = { [weak self] windowID in self?.finish(with: windowID) }
            view.onCancel = { [weak self] in self?.finish(with: nil) }
            panel.contentView = view
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
            panels.append(panel)
        }
        panels.first?.makeKeyAndOrderFront(nil)

        Task {
            do {
                let content = try await ScreenshotService.shareableContent()
                let myPID = ProcessInfo.processInfo.processIdentifier
                let windows = content.windows.filter { window in
                    window.windowLayer == 0
                        && window.owningApplication?.processID != myPID
                        && window.frame.width > 40
                        && window.frame.height > 40
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for panel in self.panels {
                        guard let view = panel.contentView as? WindowHoverView else { continue }
                        view.setWindows(windows)
                        view.updateHover(at: NSEvent.mouseLocation)
                    }
                }
            } catch {
                Log.error("Window picker failed to load shareable content: \(error)", log: Log.capture)
            }
        }
    }

    private func finish(with id: CGWindowID?) {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        let cb = completion
        completion = nil
        cb?(id)
    }
}

private final class WindowHoverView: NSView {
    var onPick: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?

    private let screenRef: NSScreen
    private var windows: [SCWindow] = []
    private var hoverFrame: NSRect = .zero
    private var hoverWindowID: CGWindowID?

    init(frame: NSRect, screen: NSScreen) {
        self.screenRef = screen
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setWindows(_ windows: [SCWindow]) {
        self.windows = windows
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        if let id = hoverWindowID {
            onPick?(id)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    func updateHover(at globalPointAppKit: CGPoint) {
        let quartzPoint = Coords.appKitGlobalToQuartz(globalPointAppKit)

        // Windows are back-to-front; keep the last match for the frontmost window.
        var match: SCWindow?
        for window in windows where window.frame.contains(quartzPoint) {
            match = window
        }

        guard let window = match else {
            hoverWindowID = nil
            hoverFrame = .zero
            needsDisplay = true
            return
        }

        hoverWindowID = window.windowID
        let appKit = Coords.quartzRectToAppKit(window.frame)
        hoverFrame = CGRect(
            x: appKit.origin.x - screenRef.frame.origin.x,
            y: appKit.origin.y - screenRef.frame.origin.y,
            width: appKit.width,
            height: appKit.height
        )
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.18).setFill()
        bounds.fill()

        guard hoverFrame.width > 0, hoverFrame.height > 0 else { return }
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: hoverFrame))
        path.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.35).setFill()
        path.fill()

        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        hoverFrame.fill()

        NSColor.systemBlue.setStroke()
        let stroke = NSBezierPath(rect: hoverFrame)
        stroke.lineWidth = 2.0
        stroke.stroke()
    }
}
