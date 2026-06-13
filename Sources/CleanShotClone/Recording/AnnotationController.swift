import AppKit

/// A button that fires on the FIRST click even when its window isn't key — every
/// recording overlay is a non-activating panel, so without this the first tap
/// just focuses the window and the user has to click twice.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Live, on-screen annotation layer for an in-progress recording.
///
/// How it ends up in the video: the overlay panel covers exactly the recorded
/// region and is deliberately NOT excluded from ScreenCaptureKit — so whatever is
/// drawn on it is composited into the frames just like the webcam bubble or click
/// ripples. The tools palette is chrome: it sits outside the region and is also
/// excluded dynamically, so it never leaks into the recording.
///
/// Interaction model (deliberately simple — no select/move):
///  - Annotate OFF → overlay ignores the mouse (the user keeps using their app)
///    while everything drawn stays on screen and keeps being recorded.
///  - Annotate ON  → overlay captures the mouse; the palette picks the tool/color
///    and offers Undo (revert last stroke), Delete All (clear), and Done (exit).
@MainActor
final class AnnotationController {
    enum Tool: CaseIterable {
        case pen, rectangle, ellipse, arrow

        var symbol: String {
            switch self {
            case .pen:       return "scribble"
            case .rectangle: return "rectangle"
            case .ellipse:   return "circle"
            case .arrow:     return "arrow.up.right"
            }
        }
        var tooltip: String {
            switch self {
            case .pen:       return "Freehand"
            case .rectangle: return "Rectangle"
            case .ellipse:   return "Circle"
            case .arrow:     return "Arrow"
            }
        }
    }

    /// Drawing surface sits ABOVE the recorded app but BELOW the tool chrome, so
    /// clicking a button always beats the overlay even after a stroke raises it.
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let chromeLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    private let regionGlobal: CGRect
    private let screen: NSScreen

    private var overlayPanel: OverlayPanel?
    private var overlayView: AnnotationOverlayView?
    private var toolbarPanel: OverlayPanel?
    private(set) var isActive = false

    /// Fired whenever annotate mode turns on/off (button taps AND the Done button),
    /// so the controls bar can keep its pencil button in sync.
    var onActiveChanged: ((Bool) -> Void)?
    /// Called with the toolbar panel once it exists, so the session can keep it
    /// out of the recording (positioned outside the region AND filter-excluded).
    var onToolbarShown: ((NSPanel) -> Void)?

    init(regionGlobal: CGRect, screen: NSScreen) {
        self.regionGlobal = regionGlobal
        self.screen = screen
    }

    func toggle() {
        isActive ? deactivate() : activate()
    }

    private func activate() {
        ensureOverlay()
        showToolbar()
        overlayView?.isInteractive = true
        overlayPanel?.ignoresMouseEvents = false
        isActive = true
        onActiveChanged?(true)
    }

    private func deactivate() {
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        overlayView?.isInteractive = false
        // Keep the overlay alive and on screen (annotations remain recorded), but
        // let the mouse fall through to the app underneath.
        overlayPanel?.ignoresMouseEvents = true
        isActive = false
        onActiveChanged?(false)
    }

    /// Final teardown when the recording ends.
    func tearDown() {
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        overlayView = nil
        isActive = false
    }

    // MARK: - Overlay (recorded)

    private func ensureOverlay() {
        guard overlayPanel == nil else { return }
        let panel = OverlayPanel(contentRect: regionGlobal, screen: screen)
        panel.level = Self.overlayLevel
        panel.setFrame(regionGlobal, display: true)
        let view = AnnotationOverlayView(frame: NSRect(origin: .zero, size: regionGlobal.size))
        panel.contentView = view
        panel.orderFrontRegardless()
        overlayPanel = panel
        overlayView = view
    }

    // MARK: - Toolbar (chrome)

    private func showToolbar() {
        if let toolbarPanel {
            toolbarPanel.orderFrontRegardless()
            return
        }
        let size = AnnotationToolbarView.toolbarSize
        // Above the region (outside the captured rect); flip below if no room.
        var origin = CGPoint(x: regionGlobal.midX - size.width / 2, y: regionGlobal.maxY + 14)
        if origin.y + size.height > screen.visibleFrame.maxY - 6 {
            origin.y = regionGlobal.minY - size.height - 14
        }
        origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)

        let panel = OverlayPanel(contentRect: CGRect(origin: origin, size: size), screen: screen)
        panel.level = Self.chromeLevel   // above the drawing overlay → always clickable
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        let view = AnnotationToolbarView(frame: NSRect(origin: .zero, size: size))
        view.onToolSelected = { [weak self] tool in self?.overlayView?.tool = tool }
        view.onColorSelected = { [weak self] color in self?.overlayView?.color = color }
        view.onUndo = { [weak self] in self?.overlayView?.undoLast() }
        view.onDeleteAll = { [weak self] in self?.overlayView?.clearAll() }
        // Done: wipe the drawings and exit — back to a clean normal recording.
        view.onDone = { [weak self] in
            self?.overlayView?.clearAll()
            self?.deactivate()
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        toolbarPanel = panel

        // Seed the overlay with the toolbar's defaults.
        overlayView?.tool = view.selectedTool
        overlayView?.color = view.selectedColor

        onToolbarShown?(panel)
    }
}

// MARK: - Annotation model

private struct LiveAnnotation {
    enum Kind {
        case pen(points: [CGPoint])
        case rect(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
    }
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
}

// MARK: - Overlay view (drawing surface, recorded)

private final class AnnotationOverlayView: NSView {
    var tool: AnnotationController.Tool = .pen {
        didSet { updateCursor() }
    }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4

    /// When false, the view draws but ignores all interaction.
    var isInteractive = false { didSet { updateCursor() } }

    private var annotations: [LiveAnnotation] = []
    private var draftPoints: [CGPoint] = []
    private var draftStart: CGPoint?
    private var draftKind: LiveAnnotation.Kind?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: External commands

    func clearAll() {
        guard !annotations.isEmpty else { return }
        annotations.removeAll()
        needsDisplay = true
    }

    func undoLast() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    private func updateCursor() {
        (isInteractive ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    // MARK: Mouse → draw

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let p = convert(event.locationInWindow, from: nil)
        draftStart = p
        switch tool {
        case .pen:       draftPoints = [p]; draftKind = .pen(points: draftPoints)
        case .rectangle: draftKind = .rect(CGRect(origin: p, size: .zero))
        case .ellipse:   draftKind = .ellipse(CGRect(origin: p, size: .zero))
        case .arrow:     draftKind = .arrow(from: p, to: p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive, let start = draftStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pen:
            if hypot(p.x - (draftPoints.last ?? start).x, p.y - (draftPoints.last ?? start).y) >= 2 {
                draftPoints.append(p)
            }
            draftKind = .pen(points: draftPoints)
        case .rectangle:
            draftKind = .rect(rect(from: start, to: p))
        case .ellipse:
            draftKind = .ellipse(rect(from: start, to: p))
        case .arrow:
            draftKind = .arrow(from: start, to: p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive else { return }
        defer { draftStart = nil; draftKind = nil; draftPoints = [] }
        guard let kind = draftKind else { return }
        // Discard degenerate shapes (a click that didn't really draw anything).
        switch kind {
        case .pen(let pts):     guard pts.count >= 2 else { return }
        case .rect(let r), .ellipse(let r): guard r.width >= 6, r.height >= 6 else { return }
        case .arrow(let f, let t): guard hypot(t.x - f.x, t.y - f.y) >= 8 else { return }
        }
        annotations.append(LiveAnnotation(kind: kind, color: color, lineWidth: lineWidth))
        needsDisplay = true
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for ann in annotations { drawAnnotation(ann, in: ctx) }
        if let kind = draftKind {
            drawAnnotation(LiveAnnotation(kind: kind, color: color, lineWidth: lineWidth), in: ctx)
        }
    }

    private func drawAnnotation(_ ann: LiveAnnotation, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(ann.color.cgColor)
        ctx.setLineWidth(ann.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch ann.kind {
        case .pen(let pts):
            guard pts.count >= 2 else { break }
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .rect(let r):
            ctx.stroke(r)
        case .ellipse(let r):
            ctx.strokeEllipse(in: r)
        case .arrow(let f, let t):
            drawArrow(from: f, to: t, lineWidth: ann.lineWidth, in: ctx)
        }
        ctx.restoreGState()
    }

    private func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, in ctx: CGContext) {
        ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = max(12, lineWidth * 3.2)
        let spread: CGFloat = .pi / 6
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - head * cos(angle - spread), y: to.y - head * sin(angle - spread)))
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - head * cos(angle + spread), y: to.y - head * sin(angle + spread)))
        ctx.strokePath()
    }
}

// MARK: - Toolbar view (chrome)

private final class AnnotationToolbarView: NSView {
    static let toolbarSize = NSSize(width: 470, height: 50)

    var onToolSelected: ((AnnotationController.Tool) -> Void)?
    var onColorSelected: ((NSColor) -> Void)?
    var onUndo: (() -> Void)?
    var onDeleteAll: (() -> Void)?
    var onDone: (() -> Void)?

    private(set) var selectedTool: AnnotationController.Tool = .pen
    private(set) var selectedColor: NSColor = .systemRed

    private var toolButtons: [AnnotationController.Tool: NSButton] = [:]
    private var colorButtons: [(NSColor, NSButton)] = []

    private static let palette: [NSColor] = [
        .systemRed, .systemYellow, .systemGreen, .systemBlue, .white
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.97).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func build() {
        var x: CGFloat = 10
        let y: CGFloat = 9
        let s: CGFloat = 32

        for tool in AnnotationController.Tool.allCases {
            let btn = FirstMouseButton(title: "", target: self, action: #selector(toolTapped(_:)))
            btn.tag = toolTag(tool)
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 8
            btn.frame = NSRect(x: x, y: y, width: s, height: s)
            styleTool(btn, tool: tool, selected: tool == selectedTool)
            addSubview(btn)
            toolButtons[tool] = btn
            x += s + 5
        }

        x += 4
        addDivider(x: x)
        x += 12

        for color in Self.palette {
            let btn = FirstMouseButton(title: "", target: self, action: #selector(colorTapped(_:)))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.frame = NSRect(x: x, y: y + 5, width: 22, height: 22)
            btn.layer?.cornerRadius = 11
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.borderWidth = color == selectedColor ? 2.5 : 1
            btn.layer?.borderColor = (color == selectedColor ? NSColor.white : NSColor.white.withAlphaComponent(0.3)).cgColor
            addSubview(btn)
            colorButtons.append((color, btn))
            x += 26
        }

        x += 2
        addDivider(x: x)
        x += 12

        let undo = iconButton("arrow.uturn.backward", tooltip: "Undo last", action: #selector(undoTapped))
        undo.frame = NSRect(x: x, y: y, width: s, height: s)
        addSubview(undo)
        x += s + 4

        let deleteAll = iconButton("trash", tooltip: "Delete all", color: .systemRed, action: #selector(deleteAllTapped))
        deleteAll.frame = NSRect(x: x, y: y, width: s, height: s)
        addSubview(deleteAll)
        x += s + 6

        addDivider(x: x)
        x += 12

        let done = FirstMouseButton(title: "Done", target: self, action: #selector(doneTapped))
        done.isBordered = false
        done.wantsLayer = true
        done.bezelStyle = .rounded
        done.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        done.contentTintColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        done.attributedTitle = NSAttributedString(string: "Done", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
        ])
        done.layer?.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
        done.layer?.cornerRadius = 8
        done.frame = NSRect(x: x, y: y + 1, width: 64, height: 30)
        addSubview(done)
    }

    private func toolTag(_ tool: AnnotationController.Tool) -> Int {
        AnnotationController.Tool.allCases.firstIndex(of: tool) ?? 0
    }
    private func tool(for tag: Int) -> AnnotationController.Tool {
        AnnotationController.Tool.allCases[tag]
    }

    private func styleTool(_ btn: NSButton, tool: AnnotationController.Tool, selected: Bool) {
        btn.toolTip = tool.tooltip
        let tint: NSColor = selected ? NSColor(calibratedWhite: 0.1, alpha: 1) : NSColor.white.withAlphaComponent(0.85)
        btn.image = symbol(tool.symbol, color: tint, size: 15)
        btn.layer?.backgroundColor = selected ? NSColor(calibratedWhite: 0.95, alpha: 1).cgColor : NSColor.clear.cgColor
    }

    private func iconButton(_ name: String, tooltip: String, color: NSColor = .white, action: Selector) -> NSButton {
        let btn = FirstMouseButton(title: "", target: self, action: action)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.toolTip = tooltip
        btn.image = symbol(name, color: color.withAlphaComponent(0.9), size: 15)
        return btn
    }

    private func symbol(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func addDivider(x: CGFloat) {
        let v = NSView(frame: NSRect(x: x, y: 9, width: 1, height: 32))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        addSubview(v)
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = tool(for: sender.tag)
        selectedTool = tool
        for (t, btn) in toolButtons { styleTool(btn, tool: t, selected: t == tool) }
        onToolSelected?(tool)
    }

    @objc private func colorTapped(_ sender: NSButton) {
        guard let pair = colorButtons.first(where: { $0.1 === sender }) else { return }
        selectedColor = pair.0
        for (color, btn) in colorButtons {
            let on = color == selectedColor
            btn.layer?.borderWidth = on ? 2.5 : 1
            btn.layer?.borderColor = (on ? NSColor.white : NSColor.white.withAlphaComponent(0.3)).cgColor
        }
        onColorSelected?(pair.0)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func deleteAllTapped() { onDeleteAll?() }
    @objc private func doneTapped() { onDone?() }
}
