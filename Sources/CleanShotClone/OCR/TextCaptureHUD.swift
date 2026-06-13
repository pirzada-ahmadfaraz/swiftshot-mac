import AppKit

/// Transient confirmation pill shown after a text capture — fades in, holds,
/// fades out. One at a time; a new capture replaces the current pill.
@MainActor
enum TextCaptureHUD {
    private static var panel: OverlayPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(title: String, detail: String?, near globalRect: CGRect) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let screen = Coords.screen(containing: globalRect) ?? NSScreen.main
        guard let screen else { return }

        let size = CGSize(width: 280, height: detail == nil ? 48 : 64)
        var origin = CGPoint(
            x: globalRect.midX - size.width / 2,
            y: globalRect.minY - size.height - 16
        )
        // Keep the pill on-screen; if the selection hugs the bottom, float above it.
        if origin.y < screen.visibleFrame.minY + 8 {
            origin.y = globalRect.maxY + 16
        }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 8),
                       screen.visibleFrame.maxX - size.width - 8)

        let frame = CGRect(origin: origin, size: size)
        let hud = OverlayPanel(contentRect: frame, screen: screen)
        hud.setFrame(frame, display: true)
        hud.ignoresMouseEvents = true

        let view = HUDView(frame: NSRect(origin: .zero, size: size))
        view.title = title
        view.detail = detail
        hud.contentView = view

        hud.alphaValue = 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            hud.animator().alphaValue = 1
        }
        panel = hud

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            guard !Task.isCancelled, panel === hud else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                hud.animator().alphaValue = 0
            }, completionHandler: {
                hud.orderOut(nil)
                if panel === hud { panel = nil }
            })
        }
    }
}

private final class HUDView: NSView {
    var title: String = ""
    var detail: String?

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 2, dy: 2)
        NSColor(white: 0.12, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let stroke = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        stroke.lineWidth = 0.5
        stroke.stroke()

        let iconSize: CGFloat = 22
        let textX = card.minX + 16 + iconSize + 10

        if let icon = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) {
            let tinted = icon.tinted(.white)
            let iconY = card.midY - iconSize / 2
            tinted.draw(in: NSRect(x: card.minX + 16, y: iconY, width: iconSize, height: iconSize))
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6)
        ]

        if let detail {
            (title as NSString).draw(at: NSPoint(x: textX, y: card.midY + 2), withAttributes: titleAttrs)
            (detail as NSString).draw(at: NSPoint(x: textX, y: card.midY - 16), withAttributes: detailAttrs)
        } else {
            let h = (title as NSString).size(withAttributes: titleAttrs).height
            (title as NSString).draw(at: NSPoint(x: textX, y: card.midY - h / 2), withAttributes: titleAttrs)
        }
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}
