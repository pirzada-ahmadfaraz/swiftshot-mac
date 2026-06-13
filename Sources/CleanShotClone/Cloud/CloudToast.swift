import AppKit

/// Transient confirmation pill for cloud actions ("Link copied", "Uploading…").
/// Floats near the bottom-center of the active screen, fades in, holds, fades out.
/// One at a time; a new toast replaces the current one. Mirrors `TextCaptureHUD`'s
/// fade logic but is self-contained and not anchored to a capture rect.
@MainActor
enum CloudToast {
    private static var panel: OverlayPanel?
    private static var dismissTask: Task<Void, Never>?

    /// Show a toast that auto-dismisses after `duration` seconds.
    static func show(title: String, detail: String? = nil, symbol: String = "link", duration: TimeInterval = 1.9) {
        present(title: title, detail: detail, symbol: symbol, autoDismissAfter: duration)
    }

    /// Show a persistent toast (e.g. "Uploading…") that stays until replaced or
    /// `dismiss()` is called. Returns immediately.
    static func showPersistent(title: String, detail: String? = nil, symbol: String = "arrow.up.circle") {
        present(title: title, detail: detail, symbol: symbol, autoDismissAfter: nil)
    }

    /// Fade out and remove any visible toast.
    static func dismiss() {
        dismissTask?.cancel()
        guard let hud = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            hud.animator().alphaValue = 0
        }, completionHandler: {
            hud.orderOut(nil)
        })
    }

    // MARK: - Internals

    private static func present(title: String, detail: String?, symbol: String, autoDismissAfter: TimeInterval?) {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil

        guard let screen = NSScreen.main else { return }

        let size = CGSize(width: 300, height: detail == nil ? 48 : 64)
        let vf = screen.visibleFrame
        let origin = CGPoint(
            x: vf.midX - size.width / 2,
            y: vf.minY + 80
        )
        let frame = CGRect(origin: origin, size: size)

        let hud = OverlayPanel(contentRect: frame, screen: screen)
        hud.setFrame(frame, display: true)
        hud.ignoresMouseEvents = true

        let view = ToastView(frame: NSRect(origin: .zero, size: size))
        view.title = title
        view.detail = detail
        view.symbol = symbol
        hud.contentView = view

        hud.alphaValue = 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            hud.animator().alphaValue = 1
        }
        panel = hud

        guard let after = autoDismissAfter else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
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

private final class ToastView: NSView {
    var title: String = ""
    var detail: String?
    var symbol: String = "link"

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

        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
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
