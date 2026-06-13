import AppKit

final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // Start dragging on the very first click, even if the overlay panel wasn't key yet.
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

    override func draw(_ dirtyRect: NSRect) {
        let hasSelection = isDragging && currentRect.width > 0 && currentRect.height > 0
        let dimColor = NSColor(white: 0, alpha: 0.35)

        if hasSelection {
            // Dim everything except the selection rect (even-odd fill) — the selected
            // area stays at full brightness so you see exactly what you're capturing.
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: currentRect))
            path.windingRule = .evenOdd
            dimColor.setFill()
            path.fill()

            // Subtle neutral border around the selection (no loud blue).
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let stroke = NSBezierPath(rect: currentRect)
            stroke.lineWidth = 1.0
            stroke.stroke()
        } else {
            dimColor.setFill()
            bounds.fill()
            return
        }

        // Size badge.
        let label = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let badgeWidth = size.width + 12
        let badgeHeight: CGFloat = 20
        let badgeOrigin = NSPoint(
            x: min(currentRect.maxX - badgeWidth, bounds.maxX - badgeWidth - 8),
            y: max(currentRect.minY - badgeHeight - 6, 8)
        )
        let badgeRect = NSRect(x: badgeOrigin.x, y: badgeOrigin.y, width: badgeWidth, height: badgeHeight)
        NSColor(white: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
        let labelOrigin = NSPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3)
        (label as NSString).draw(at: labelOrigin, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            isDragging = false
        }
        guard currentRect.width >= 4, currentRect.height >= 4 else {
            onCancel?()
            return
        }
        onSelection?(currentRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
