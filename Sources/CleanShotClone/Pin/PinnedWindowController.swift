import AppKit

/// A pinned screenshot uses the exact same card UI as the quick-action popup, but with
/// the buttons permanently visible (no hover toggle) and dragging repositions the window.
@MainActor
final class PinnedWindowController {
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?

    private let image: CGImage
    private let initialRect: CGRect?
    private var window: CardPanel?

    init(image: CGImage, atGlobalRect rect: CGRect?) {
        self.image = image
        self.initialRect = rect
    }

    func show() {
        let frame: NSRect
        if let initialRect, initialRect.width > 1, initialRect.height > 1 {
            frame = initialRect
        } else {
            let size = ScreenshotCardController.cardSize
            let screen = Coords.screenUnderMouse() ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            frame = NSRect(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.midY - size.height / 2,
                width: size.width, height: size.height
            )
        }

        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let model = CardModel(image: nsImage, horizontalActions: true)
        model.onCopy = { [weak self] in self?.copy() }
        model.onSave = { [weak self] in self?.save() }
        model.onEdit = { [weak self] in self?.onEdit?() }
        model.onClose = { [weak self] in self?.close() }
        model.onPin = {}
        model.onCloud = {}

        let view = CardView(frame: NSRect(origin: .zero, size: frame.size), cgImage: image, model: model, pinned: true)

        let panel = CardPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.setFrameOrigin(frame.origin)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.window = panel
    }

    func close() {
        guard let window else { onClose?(); return }
        self.window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.onClose?()
        })
    }

    private func copy() {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Pinned Screenshot.png"
        NSApp.activate(ignoringOtherApps: true)
        let image = self.image
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Could not save screenshot"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}
