import AppKit

/// Click ripples drawn at the mouse location during recording. The ripple panels
/// are on-screen windows that are NOT excluded from capture, so they appear in
/// the recording. Requires Accessibility trust for clicks outside our windows.
@MainActor
final class ClickHighlighter {
    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.spawnRipple(at: NSEvent.mouseLocation) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            monitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handler(event)
            return event
        }
        if let local { monitors.append(local) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func spawnRipple(at globalPoint: NSPoint) {
        let d: CGFloat = 56
        let frame = NSRect(x: globalPoint.x - d / 2, y: globalPoint.y - d / 2, width: d, height: d)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let circle = CAShapeLayer()
        circle.path = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: d - 8, height: d - 8), transform: nil)
        circle.fillColor = NSColor.systemYellow.withAlphaComponent(0.45).cgColor
        circle.strokeColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        circle.lineWidth = 2
        view.layer?.addSublayer(circle)
        panel.contentView = view
        panel.orderFrontRegardless()

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.35
        scale.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        circle.add(group, forKey: "ripple")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            panel.orderOut(nil)
        }
    }
}

/// Keystroke pill shown at the bottom-center of the recorded region — inside the
/// region so it's captured. Requires Accessibility trust for global key events.
@MainActor
final class KeystrokeOverlay {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var monitors: [Any] = []
    private var fadeTask: Task<Void, Never>?

    func start(regionGlobal: CGRect) {
        guard monitors.isEmpty else { return }

        let size = NSSize(width: 240, height: 44)
        let frame = NSRect(
            x: regionGlobal.midX - size.width / 2,
            y: regionGlobal.minY + 20,
            width: size.width, height: size.height
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.82).cgColor
        container.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 9, width: size.width - 16, height: 26)
        container.addSubview(label)
        panel.contentView = container
        panel.orderFrontRegardless()

        self.panel = panel
        self.label = label

        let handler: (NSEvent) -> Void = { [weak self] event in
            let text = Self.describe(event)
            Task { @MainActor in self?.flash(text) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: handler) {
            monitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handler(event)
            return event
        }
        if let local { monitors.append(local) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        fadeTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }

    private func flash(_ text: String) {
        guard let panel, let label else { return }
        label.stringValue = text
        panel.alphaValue = 1
        fadeTask?.cancel()
        fadeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.3
            panel.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
    }

    private static func describe(_ event: NSEvent) -> String {
        var parts = ""
        let f = event.modifierFlags
        if f.contains(.control) { parts += "⌃" }
        if f.contains(.option) { parts += "⌥" }
        if f.contains(.shift) { parts += "⇧" }
        if f.contains(.command) { parts += "⌘" }

        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"
        ]
        if let s = special[event.keyCode] {
            return parts + s
        }
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        return parts + key
    }
}
