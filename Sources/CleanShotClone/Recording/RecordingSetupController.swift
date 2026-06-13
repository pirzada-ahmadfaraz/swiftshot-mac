import AppKit
import ScreenCaptureKit

enum RecordingMode {
    case video, gif
}

struct RecordingSetupResult {
    let globalRect: CGRect
    let screen: NSScreen
    let mode: RecordingMode
}

/// Pre-recording flow: instruction pill → drag a region (or Space → pick a
/// window) → adjust with handles → options panel (size, audio/webcam/cursor
/// toggles) → Record GIF (⌥↩) / Record Video (↩).
@MainActor
final class RecordingSetupController {
    private var panels: [OverlayPanel] = []
    private var optionsPanel: OverlayPanel?
    private var completion: ((RecordingSetupResult?) -> Void)?
    private var settings = RecordingSettings.load()

    var onOpenSettings: (() -> Void)?

    func start(completion: @escaping (RecordingSetupResult?) -> Void) {
        guard panels.isEmpty else { return }
        self.completion = completion
        self.settings = RecordingSettings.load()

        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, screen: screen)
            let view = RecordingSetupView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
            view.onSelectionChanged = { [weak self] globalRect in
                self?.selectionChanged(globalRect, on: screen)
            }
            view.onCommit = { [weak self] mode in self?.commit(mode: mode) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            view.onToggleWindowMode = { [weak self] in self?.toggleWindowMode() }
            panel.contentView = view
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
            panels.append(panel)
        }
        panels.first?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
        loadWindowsForPicking()

        // Remembered selection: jump straight to the adjust phase.
        if settings.rememberLastSelection, let last = settings.lastSelection,
           let screen = Coords.screen(containing: last),
           screen.frame.intersects(last) {
            let clamped = last.intersection(screen.frame)
            if clamped.width >= 40, clamped.height >= 40 {
                view(for: screen)?.adoptSelection(globalRect: clamped)
                selectionChanged(clamped, on: screen)
            }
        }
    }

    // MARK: - Phase plumbing

    private var currentRect: CGRect = .zero
    private var currentScreen: NSScreen?

    private func view(for screen: NSScreen) -> RecordingSetupView? {
        panels.compactMap { $0.contentView as? RecordingSetupView }.first { $0.screenRef === screen }
    }

    private func selectionChanged(_ globalRect: CGRect, on screen: NSScreen) {
        currentRect = globalRect
        currentScreen = screen
        // Clear any selection drawn on other screens.
        for p in panels {
            guard let v = p.contentView as? RecordingSetupView, v.screenRef !== screen else { continue }
            v.clearSelection()
        }
        showOrUpdateOptionsPanel()
    }

    private func toggleWindowMode() {
        for p in panels {
            (p.contentView as? RecordingSetupView)?.toggleWindowMode()
        }
        hideOptionsPanel()
    }

    private func loadWindowsForPicking() {
        Task {
            guard let content = try? await ScreenshotService.shareableContent() else { return }
            let myPID = ProcessInfo.processInfo.processIdentifier
            let windows = content.windows.filter {
                $0.windowLayer == 0
                    && $0.owningApplication?.processID != myPID
                    && $0.frame.width > 40 && $0.frame.height > 40
            }
            await MainActor.run {
                for p in self.panels {
                    (p.contentView as? RecordingSetupView)?.pickableWindows = windows
                }
            }
        }
    }

    // MARK: - Options panel

    private func showOrUpdateOptionsPanel() {
        guard let screen = currentScreen, currentRect.width >= 40, currentRect.height >= 40 else {
            hideOptionsPanel()
            return
        }

        let size = RecordOptionsView.panelSize
        var origin = CGPoint(x: currentRect.midX - size.width / 2, y: currentRect.maxY - size.height - 20)
        if currentRect.height < size.height + 80 {
            origin.y = currentRect.maxY + 12   // small selection: float above
        }
        origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)
        let frame = CGRect(origin: origin, size: size)

        if let panel = optionsPanel {
            panel.setFrame(frame, display: true)
            (panel.contentView as? RecordOptionsView)?.update(rect: currentRect)
            return
        }

        let panel = OverlayPanel(contentRect: frame, screen: screen)
        panel.setFrame(frame, display: true)
        let view = RecordOptionsView(frame: NSRect(origin: .zero, size: size))
        view.settingsProvider = { [weak self] in self?.settings ?? RecordingSettings.load() }
        view.onSettingsChanged = { [weak self] new in
            self?.settings = new
            new.save()
        }
        view.onSizeEdited = { [weak self] w, h in self?.resizeSelection(w: w, h: h) }
        view.onExpand = { [weak self] in self?.expandToFullScreen() }
        view.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        view.onRecord = { [weak self] mode in self?.commit(mode: mode) }
        view.update(rect: currentRect)
        panel.contentView = view
        panel.orderFrontRegardless()
        optionsPanel = panel
    }

    private func hideOptionsPanel() {
        optionsPanel?.orderOut(nil)
        optionsPanel = nil
    }

    private func resizeSelection(w: CGFloat, h: CGFloat) {
        guard let screen = currentScreen, w >= 40, h >= 40 else { return }
        var r = currentRect
        r.size = CGSize(width: w, height: h)
        // Keep the top-left corner anchored (AppKit coords: top = maxY).
        r.origin.y = currentRect.maxY - h
        r = r.intersection(screen.frame)
        guard r.width >= 40, r.height >= 40 else { return }
        view(for: screen)?.adoptSelection(globalRect: r)
        selectionChanged(r, on: screen)
    }

    private func expandToFullScreen() {
        guard let screen = currentScreen ?? Coords.screenUnderMouse() else { return }
        let r = screen.frame
        view(for: screen)?.adoptSelection(globalRect: r)
        selectionChanged(r, on: screen)
    }

    // MARK: - Commit / cancel

    private func commit(mode: RecordingMode) {
        guard let screen = currentScreen, currentRect.width >= 40, currentRect.height >= 40 else { return }
        var s = settings
        s.lastSelection = currentRect
        s.save()
        let result = RecordingSetupResult(globalRect: currentRect, screen: screen, mode: mode)
        finish(result)
    }

    private func finish(_ result: RecordingSetupResult?) {
        NSCursor.arrow.set()
        hideOptionsPanel()
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        let cb = completion
        completion = nil
        cb?(result)
    }
}

// MARK: - Selection / window-pick view (one per screen)

private final class RecordingSetupView: NSView {
    let screenRef: NSScreen
    var onSelectionChanged: ((CGRect) -> Void)?
    var onCommit: ((RecordingMode) -> Void)?
    var onCancel: (() -> Void)?
    var onToggleWindowMode: (() -> Void)?
    var pickableWindows: [SCWindow] = []

    private enum Phase { case idle, dragging, adjust, windowPick }
    private var phase: Phase = .idle

    private var selection: NSRect = .zero      // view-local
    private var dragStart: NSPoint?
    private var activeHandle: Handle?
    private var moveOrigin: NSPoint?
    private var selectionAtGestureStart: NSRect = .zero
    private var hoverWindowFrame: NSRect = .zero

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    init(frame: NSRect, screen: NSScreen) {
        self.screenRef = screen
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: External control

    func adoptSelection(globalRect: CGRect) {
        selection = NSRect(
            x: globalRect.origin.x - screenRef.frame.origin.x,
            y: globalRect.origin.y - screenRef.frame.origin.y,
            width: globalRect.width, height: globalRect.height
        )
        phase = .adjust
        needsDisplay = true
    }

    func clearSelection() {
        if phase == .adjust || phase == .dragging {
            selection = .zero
            phase = .idle
            needsDisplay = true
        }
    }

    func toggleWindowMode() {
        if phase == .windowPick {
            phase = selection.width > 0 ? .adjust : .idle
        } else {
            phase = .windowPick
            updateHover(at: NSEvent.mouseLocation)
        }
        needsDisplay = true
    }

    private var globalSelection: CGRect {
        CGRect(
            x: selection.origin.x + screenRef.frame.origin.x,
            y: selection.origin.y + screenRef.frame.origin.y,
            width: selection.width, height: selection.height
        )
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        if phase == .windowPick {
            updateHover(at: NSEvent.mouseLocation)
        } else if phase == .adjust {
            updateCursor(for: convert(event.locationInWindow, from: nil))
        }
    }

    private func updateCursor(for p: NSPoint) {
        if handle(at: p) != nil {
            NSCursor.crosshair.set()
        } else if selection.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func updateHover(at globalPointAppKit: CGPoint) {
        let quartz = Coords.appKitGlobalToQuartz(globalPointAppKit)
        var match: SCWindow?
        for w in pickableWindows where w.frame.contains(quartz) { match = w }
        if let w = match {
            let appKit = Coords.quartzRectToAppKit(w.frame)
            hoverWindowFrame = NSRect(
                x: appKit.origin.x - screenRef.frame.origin.x,
                y: appKit.origin.y - screenRef.frame.origin.y,
                width: appKit.width, height: appKit.height
            )
        } else {
            hoverWindowFrame = .zero
        }
        needsDisplay = true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch phase {
        case .windowPick:
            if hoverWindowFrame.width > 0 {
                let global = CGRect(
                    x: hoverWindowFrame.origin.x + screenRef.frame.origin.x,
                    y: hoverWindowFrame.origin.y + screenRef.frame.origin.y,
                    width: hoverWindowFrame.width, height: hoverWindowFrame.height
                ).intersection(screenRef.frame)
                guard global.width >= 40, global.height >= 40 else { return }
                adoptSelection(globalRect: global)
                onSelectionChanged?(global)
            }
        case .adjust:
            if let h = handle(at: p) {
                activeHandle = h
                selectionAtGestureStart = selection
                dragStart = p
            } else if selection.contains(p) {
                moveOrigin = p
                selectionAtGestureStart = selection
                NSCursor.closedHand.set()
            } else {
                phase = .dragging
                dragStart = p
                selection = .zero
                needsDisplay = true
            }
        case .idle:
            phase = .dragging
            dragStart = p
            selection = .zero
            needsDisplay = true
        case .dragging:
            dragStart = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch phase {
        case .dragging:
            guard let start = dragStart else { return }
            selection = NSRect(
                x: min(start.x, p.x), y: min(start.y, p.y),
                width: abs(p.x - start.x), height: abs(p.y - start.y)
            )
            needsDisplay = true
        case .adjust:
            if let h = activeHandle, let start = dragStart {
                selection = Self.resize(selectionAtGestureStart, handle: h, dx: p.x - start.x, dy: p.y - start.y)
                clampSelection()
                needsDisplay = true
                onSelectionChanged?(globalSelection)
            } else if let origin = moveOrigin {
                selection = selectionAtGestureStart.offsetBy(dx: p.x - origin.x, dy: p.y - origin.y)
                clampSelection()
                needsDisplay = true
                onSelectionChanged?(globalSelection)
            }
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case .dragging:
            defer { dragStart = nil }
            if selection.width >= 40, selection.height >= 40 {
                phase = .adjust
                onSelectionChanged?(globalSelection)
            } else {
                selection = .zero
                phase = .idle
            }
            needsDisplay = true
        case .adjust:
            activeHandle = nil
            moveOrigin = nil
            dragStart = nil
            updateCursor(for: convert(event.locationInWindow, from: nil))
        default:
            break
        }
    }

    private func clampSelection() {
        selection = selection.intersection(bounds)
        if selection.width < 40 { selection.size.width = 40 }
        if selection.height < 40 { selection.size.height = 40 }
    }

    private static func resize(_ r: NSRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> NSRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .topLeft:     minX += dx; maxY += dy
        case .top:         maxY += dy
        case .topRight:    maxX += dx; maxY += dy
        case .right:       maxX += dx
        case .bottomRight: maxX += dx; minY += dy
        case .bottom:      minY += dy
        case .bottomLeft:  minX += dx; minY += dy
        case .left:        minX += dx
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func handlePoints(_ r: NSRect) -> [(Handle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.top, CGPoint(x: r.midX, y: r.maxY)),
            (.topRight, CGPoint(x: r.maxX, y: r.maxY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.minY)), (.bottom, CGPoint(x: r.midX, y: r.minY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    private func handle(at p: NSPoint) -> Handle? {
        guard selection.width > 0 else { return nil }
        for (h, pt) in handlePoints(selection) {
            if abs(p.x - pt.x) <= 10 && abs(p.y - pt.y) <= 10 { return h }
        }
        return nil
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                                  // esc
        case 49: onToggleWindowMode?()                        // space
        case 36, 76:                                          // return / keypad-enter
            guard phase == .adjust else { return }
            onCommit?(event.modifierFlags.contains(.option) ? .gif : .video)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch phase {
        case .windowPick:
            NSColor(white: 0, alpha: 0.25).setFill()
            bounds.fill()
            if hoverWindowFrame.width > 0 {
                NSColor.systemBlue.withAlphaComponent(0.2).setFill()
                hoverWindowFrame.fill()
                NSColor.systemBlue.setStroke()
                let stroke = NSBezierPath(rect: hoverWindowFrame)
                stroke.lineWidth = 2
                stroke.stroke()
            }
            drawInstructionPill("Click a window to record it. Press Space to select an area.")

        case .idle:
            NSColor(white: 0, alpha: 0.3).setFill()
            bounds.fill()
            drawInstructionPill("Drag to record a part of the screen. Press Space to select a window.")

        case .dragging, .adjust:
            let r = selection
            let path = NSBezierPath(rect: bounds)
            if r.width > 1 { path.append(NSBezierPath(rect: r)) }
            path.windingRule = .evenOdd
            NSColor(white: 0, alpha: 0.42).setFill()
            path.fill()
            guard r.width > 1 else { return }
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let stroke = NSBezierPath(rect: r)
            stroke.lineWidth = 1.5
            stroke.stroke()
            if phase == .adjust {
                NSColor.white.setFill()
                for (_, pt) in handlePoints(r) {
                    NSBezierPath(ovalIn: NSRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)).fill()
                }
            }
        }
    }

    private func drawInstructionPill(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pillW = textSize.width + 44
        let pillH: CGFloat = 40
        let pill = NSRect(x: bounds.midX - pillW / 2, y: bounds.maxY - 120, width: pillW, height: pillH)
        NSColor(calibratedWhite: 0.99, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
        (text as NSString).draw(
            at: NSPoint(x: pill.minX + 22, y: pill.midY - textSize.height / 2),
            withAttributes: attrs
        )
    }
}

// MARK: - Options panel

private final class RecordOptionsView: NSView, NSTextFieldDelegate {
    static let panelSize = NSSize(width: 330, height: 216)

    var settingsProvider: (() -> RecordingSettings)?
    var onSettingsChanged: ((RecordingSettings) -> Void)?
    var onSizeEdited: ((CGFloat, CGFloat) -> Void)?
    var onExpand: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRecord: ((RecordingMode) -> Void)?

    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var toggleButtons: [String: NSButton] = [:]
    private var shapeControl: NSSegmentedControl!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.96).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func buildUI() {
        let s = settingsProvider?() ?? RecordingSettings.load()

        // Row 1: settings gear | W x H | expand
        addIconButton(symbol: "slider.horizontal.3", x: 14, y: 12, tooltip: "Recording Settings") { [weak self] in
            self?.onOpenSettings?()
        }

        configureSizeField(widthField, x: 78, y: 14)
        let xLabel = NSTextField(labelWithString: "×")
        xLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        xLabel.font = NSFont.systemFont(ofSize: 12)
        xLabel.frame = NSRect(x: 158, y: 18, width: 14, height: 18)
        addSubview(xLabel)
        configureSizeField(heightField, x: 176, y: 14)

        addIconButton(symbol: "arrow.up.left.and.arrow.down.right", x: 282, y: 12, tooltip: "Expand to full screen") { [weak self] in
            self?.onExpand?()
        }

        // Row 2: capture toggles
        let toggles: [(key: String, symbol: String, tip: String, isOn: (RecordingSettings) -> Bool, set: (inout RecordingSettings, Bool) -> Void)] = [
            ("mic", "mic.fill", "Microphone", { $0.captureMicrophone }, { $0.captureMicrophone = $1 }),
            ("sys", "speaker.wave.2.fill", "System Audio", { $0.captureSystemAudio }, { $0.captureSystemAudio = $1 }),
            ("cam", "video.fill", "Webcam Overlay", { $0.webcamEnabled }, { $0.webcamEnabled = $1 }),
            ("clk", "cursorarrow.rays", "Highlight Clicks", { $0.highlightClicks }, { $0.highlightClicks = $1 }),
            ("key", "command", "Show Keystrokes", { $0.showKeystrokes }, { $0.showKeystrokes = $1 }),
        ]
        let toggleW: CGFloat = 54
        let totalW = CGFloat(toggles.count) * toggleW + CGFloat(toggles.count - 1) * 6
        var tx = (Self.panelSize.width - totalW) / 2
        for t in toggles {
            let btn = NSButton(title: "", target: self, action: #selector(toggleTapped(_:)))
            btn.identifier = NSUserInterfaceItemIdentifier(t.key)
            btn.toolTip = t.tip
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 9
            btn.frame = NSRect(x: tx, y: 52, width: toggleW, height: 34)
            styleToggle(btn, symbol: t.symbol, on: t.isOn(s))
            addSubview(btn)
            toggleButtons[t.key] = btn
            tx += toggleW + 6
        }

        // Webcam shape (enabled when webcam is on)
        let shapeLabel = NSTextField(labelWithString: "Webcam:")
        shapeLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        shapeLabel.font = NSFont.systemFont(ofSize: 11)
        shapeLabel.frame = NSRect(x: 70, y: 98, width: 60, height: 16)
        addSubview(shapeLabel)

        shapeControl = NSSegmentedControl(labels: ["Rounded", "Circle"], trackingMode: .selectOne, target: self, action: #selector(shapeChanged))
        shapeControl.frame = NSRect(x: 134, y: 94, width: 130, height: 22)
        shapeControl.selectedSegment = s.webcamShape == .circle ? 1 : 0
        shapeControl.appearance = NSAppearance(named: .darkAqua)
        shapeControl.isEnabled = s.webcamEnabled
        addSubview(shapeControl)

        // Separator
        let sep = NSView(frame: NSRect(x: 12, y: 126, width: Self.panelSize.width - 24, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        addSubview(sep)

        // Record rows
        addRecordRow(y: 132, symbol: "gift.fill", useGIFBadge: true, title: "Record GIF", shortcut: "⌥ ↩", mode: .gif)
        addRecordRow(y: 172, symbol: "video.fill", useGIFBadge: false, title: "Record Video", shortcut: "↩", mode: .video)
    }

    private func configureSizeField(_ field: NSTextField, x: CGFloat, y: CGFloat) {
        field.frame = NSRect(x: x, y: y, width: 74, height: 26)
        field.alignment = .center
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        field.textColor = .white
        field.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        field.isBordered = false
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
    }

    private func addIconButton(symbol: String, x: CGFloat, y: CGFloat, tooltip: String, action: @escaping () -> Void) {
        let btn = HoverIconButton(symbol: symbol, action: action)
        btn.toolTip = tooltip
        btn.frame = NSRect(x: x, y: y, width: 34, height: 30)
        addSubview(btn)
    }

    private func styleToggle(_ btn: NSButton, symbol: String, on: Bool) {
        let color: NSColor = on ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.white.withAlphaComponent(0.75)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        btn.layer?.backgroundColor = on
            ? NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
        btn.setAccessibilityValue(on ? "on" : "off")
    }

    @objc private func toggleTapped(_ sender: NSButton) {
        guard var s = settingsProvider?(), let key = sender.identifier?.rawValue else { return }
        let symbols = ["mic": "mic.fill", "sys": "speaker.wave.2.fill", "cam": "video.fill", "clk": "cursorarrow.rays", "key": "command"]
        let newValue: Bool
        switch key {
        case "mic": s.captureMicrophone.toggle(); newValue = s.captureMicrophone
        case "sys": s.captureSystemAudio.toggle(); newValue = s.captureSystemAudio
        case "cam": s.webcamEnabled.toggle(); newValue = s.webcamEnabled; shapeControl.isEnabled = newValue
        case "clk": s.highlightClicks.toggle(); newValue = s.highlightClicks
        case "key": s.showKeystrokes.toggle(); newValue = s.showKeystrokes
        default: return
        }
        styleToggle(sender, symbol: symbols[key] ?? "questionmark", on: newValue)
        onSettingsChanged?(s)

        // Permissions that need a heads-up the first time they're enabled.
        if newValue, key == "cam" { AVPermission.requestCamera() }
        if newValue, key == "mic" { AVPermission.requestMicrophone() }
        if newValue, key == "clk" || key == "key" { AVPermission.promptAccessibilityIfNeeded() }
    }

    @objc private func shapeChanged() {
        guard var s = settingsProvider?() else { return }
        s.webcamShape = shapeControl.selectedSegment == 1 ? .circle : .roundedRectangle
        onSettingsChanged?(s)
    }

    private func addRecordRow(y: CGFloat, symbol: String, useGIFBadge: Bool, title: String, shortcut: String, mode: RecordingMode) {
        let row = RecordRowButton(
            badge: useGIFBadge ? "GIF" : nil,
            symbol: useGIFBadge ? nil : symbol,
            title: title,
            shortcut: shortcut
        ) { [weak self] in
            self?.onRecord?(mode)
        }
        row.frame = NSRect(x: 8, y: y, width: Self.panelSize.width - 16, height: 36)
        addSubview(row)
    }

    func update(rect: CGRect) {
        let editing = (window?.firstResponder as? NSText)?.delegate === widthField
            || (window?.firstResponder as? NSText)?.delegate === heightField
        guard !editing else { return }
        widthField.stringValue = String(Int(rect.width))
        heightField.stringValue = String(Int(rect.height))
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let w = CGFloat(Int(widthField.stringValue) ?? 0)
        let h = CGFloat(Int(heightField.stringValue) ?? 0)
        if w >= 40, h >= 40 { onSizeEdited?(w, h) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onRecord?(event.modifierFlags.contains(.option) ? .gif : .video)
        } else if event.keyCode == 53 {
            // Esc falls through to the selection overlays via the controller's cancel path.
            super.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Flat icon button with a hover highlight.
private final class HoverIconButton: NSView {
    private let action: () -> Void
    private let imageView = NSImageView()

    init(symbol: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.8)]))
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 7, dy: 5)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

/// "Record GIF / Record Video" row: badge or icon + title + shortcut hint.
private final class RecordRowButton: NSView {
    private let action: () -> Void

    init(badge: String?, symbol: String?, title: String, shortcut: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        var x: CGFloat = 10
        if let badge {
            let badgeLabel = NSTextField(labelWithString: badge)
            badgeLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
            badgeLabel.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
            badgeLabel.alignment = .center
            badgeLabel.wantsLayer = true
            badgeLabel.layer?.backgroundColor = NSColor.white.cgColor
            badgeLabel.layer?.cornerRadius = 4
            badgeLabel.frame = NSRect(x: x, y: 10, width: 30, height: 16)
            addSubview(badgeLabel)
            x += 40
        } else if let symbol {
            let iv = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.9)]))
            iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            iv.frame = NSRect(x: x, y: 9, width: 22, height: 18)
            addSubview(iv)
            x += 32
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: x, y: 9, width: 160, height: 18)
        addSubview(titleLabel)

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = NSFont.systemFont(ofSize: 13)
        shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        shortcutLabel.alignment = .right
        shortcutLabel.frame = NSRect(x: 230, y: 9, width: 74, height: 18)
        shortcutLabel.autoresizingMask = [.minXMargin]
        addSubview(shortcutLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

// MARK: - Permission helpers

import AVFoundation

enum AVPermission {
    /// TCC KILLS the process when requestAccess is called without the matching
    /// usage description in the app's Info.plist. Every entry point below guards
    /// that first, so a misassembled bundle degrades to an alert — never a crash.
    static func hasUsageDescription(_ key: String) -> Bool {
        Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    static func requestCamera() {
        request(.video, descriptionKey: "NSCameraUsageDescription", label: "Camera")
    }

    static func requestMicrophone() {
        request(.audio, descriptionKey: "NSMicrophoneUsageDescription", label: "Microphone")
    }

    private static func request(_ type: AVMediaType, descriptionKey: String, label: String) {
        guard hasUsageDescription(descriptionKey) else {
            Task { @MainActor in warnMissingUsageDescription(label) }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: type) { _ in }
        case .denied, .restricted:
            Task { @MainActor in notifyDenied(label, type: type) }
        default:
            break
        }
    }

    /// Awaitable variant used at recording start: true only when fully
    /// authorized. Never crashes; never blocks past the user's answer.
    static func ensureMicrophone() async -> Bool {
        await ensure(.audio, descriptionKey: "NSMicrophoneUsageDescription", label: "Microphone")
    }

    static func ensureCamera() async -> Bool {
        await ensure(.video, descriptionKey: "NSCameraUsageDescription", label: "Camera")
    }

    private static func ensure(_ type: AVMediaType, descriptionKey: String, label: String) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return true
        case .notDetermined:
            guard hasUsageDescription(descriptionKey) else {
                await MainActor.run { warnMissingUsageDescription(label) }
                return false
            }
            return await AVCaptureDevice.requestAccess(for: type)
        default:
            return false
        }
    }

    /// Click/keystroke overlays use global event monitors, which require
    /// Accessibility trust. Prompt once via the system dialog.
    static func promptAccessibilityIfNeeded() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @MainActor private static var warnedMissingDescription = false

    @MainActor
    private static func warnMissingUsageDescription(_ label: String) {
        guard !warnedMissingDescription else { return }
        warnedMissingDescription = true
        let alert = NSAlert()
        alert.messageText = "\(label) access unavailable in this build"
        alert.informativeText = "The app bundle is missing its privacy usage descriptions. Rebuild it with ./make-app.sh so macOS can ask for permission."
        alert.alertStyle = .warning
        alert.runModal()
    }

    @MainActor
    private static func notifyDenied(_ label: String, type: AVMediaType) {
        let alert = NSAlert()
        alert.messageText = "\(label) access is turned off"
        alert.informativeText = "Enable it for SwiftShot in System Settings → Privacy & Security."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            let pane = type == .audio ? "Privacy_Microphone" : "Privacy_Camera"
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
