import AppKit

/// Spans every NSScreen with a transparent overlay panel and lets the user drag a rect.
/// Result is a CGRect in AppKit global desktop coordinates.
final class RegionSelectionController {
    private var panels: [OverlayPanel] = []
    private var completion: ((CGRect?) -> Void)?

    func start(completion: @escaping (CGRect?) -> Void) {
        guard panels.isEmpty else { return }
        self.completion = completion

        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, screen: screen)
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onSelection = { [weak self] viewRect in
                guard let self else { return }
                let globalOrigin = CGPoint(
                    x: viewRect.origin.x + screen.frame.origin.x,
                    y: viewRect.origin.y + screen.frame.origin.y
                )
                let globalRect = CGRect(origin: globalOrigin, size: viewRect.size)
                self.finish(with: globalRect)
            }
            view.onCancel = { [weak self] in self?.finish(with: nil) }

            panel.contentView = view
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
            panels.append(panel)
        }

        // Make the first overlay key so ESC and the first click are received immediately.
        // NOTE: we deliberately do NOT call NSApp.activate here — activating would pull any
        // open editor/pinned windows to the front. acceptsFirstMouse handles the first click.
        panels.first?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    private func finish(with rect: CGRect?) {
        NSCursor.arrow.set()
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        let cb = completion
        completion = nil
        cb?(rect)
    }
}

/// Borderless, transparent, above-everything panel used for overlays.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, screen: NSScreen?) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .screenSaver
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.isReleasedWhenClosed = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hidesOnDeactivate = false
        if let screen { self.setFrame(screen.frame, display: true) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
