import AppKit
import ScreenCaptureKit

/// Full scrolling-capture flow: region select → Start Capture → live stitch → Done.
@MainActor
final class ScrollingCaptureController {
    private var panels: [OverlayPanel] = []
    private var previewPanel: OverlayPanel?
    private var controlsPanel: OverlayPanel?
    private var completion: ((CGImage?) -> Void)?

    private var globalRect: CGRect = .zero
    private var screen: NSScreen?
    private var displayLocalRect: CGRect = .zero
    private var scDisplay: SCDisplay?
    private var captureScale: CGFloat = 2

    private var stitchedImage: CGImage?
    private var lastFrame: CGImage?       // reference frame: last frame that stitched successfully
    private var lastRawFrame: CGImage?    // most recent capture, matched or not (stability tracking)
    private var bottomExclude = 0         // fixed-footer rows withheld from appends (sticky max)
    private var consecutiveMisses = 0     // changed-but-unmatchable frames in a row
    private var sessionTimer: Timer?
    private var sessionExclude: [SCWindow] = []
    private var isCapturing = false
    private var captureInFlight = false

    /// Memory safety net — stop growing the stitch beyond this many pixel rows.
    private static let maxStitchedHeight = 40_000
    /// Unmatchable ticks before we consider sync lost and re-baseline once stable.
    private static let rebaseMissThreshold = 5

    /// Result of one capture tick, computed off the main actor.
    private enum StitchOutcome {
        case first(stitched: CGImage, frame: CGImage)
        case appended(stitched: CGImage, frame: CGImage, bottomExclude: Int)
        case rebased(stitched: CGImage, frame: CGImage)
        case unchanged(frame: CGImage, isStationary: Bool)
        case failed
    }

    func start(completion: @escaping (CGImage?) -> Void) {
        guard panels.isEmpty else { return }
        self.completion = completion
        showSelectionOverlays()
        NSCursor.crosshair.set()
    }

    // MARK: - Phase 1: selection overlays

    private func showSelectionOverlays() {
        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, screen: screen)
            let view = ScrollingSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.onConfirmed = { [weak self] globalRect in
                self?.beginCaptureSetup(globalRect: globalRect)
            }
            view.onCancel = { [weak self] in self?.finish(with: nil) }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        panels.first?.makeKeyAndOrderFront(nil)
    }

    private func beginCaptureSetup(globalRect: CGRect) {
        guard let screen = Coords.screen(containing: globalRect) else {
            finish(with: nil)
            return
        }
        self.globalRect = globalRect
        self.screen = screen
        self.displayLocalRect = Coords.toDisplayLocal(globalRect, on: screen)
        self.captureScale = screen.backingScaleFactor

        Task {
            do {
                let content = try await ScreenshotService.shareableContent()
                guard let display = Coords.scDisplay(for: screen, in: content) else {
                    await MainActor.run { self.finish(with: nil) }
                    return
                }
                await MainActor.run {
                    self.scDisplay = display
                    self.showConfirmUI(on: screen)
                }
            } catch {
                Log.error("Scrolling capture setup failed: \(error)", log: Log.capture)
                await MainActor.run { self.finish(with: nil) }
            }
        }
    }

    // MARK: - Phase 2: confirm + Start Capture

    private func showConfirmUI(on screen: NSScreen) {
        tearDownPanels()
        let panel = OverlayPanel(contentRect: screen.frame, screen: screen)
        let view = ScrollingConfirmView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.screenFrame = screen.frame
        view.selectionGlobal = globalRect
        view.onStart = { [weak self] in self?.startScrollingSession() }
        view.onCancel = { [weak self] in self?.finish(with: nil) }
        view.onAdjust = { [weak self] newGlobal in
            self?.globalRect = newGlobal
            if let s = self?.screen {
                self?.displayLocalRect = Coords.toDisplayLocal(newGlobal, on: s)
            }
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panels = [panel]
        NSCursor.arrow.set()
    }

    // MARK: - Phase 3: scrolling session

    private func startScrollingSession() {
        guard scDisplay != nil else { finish(with: nil); return }
        isCapturing = true
        tearDownPanels()
        Task { @MainActor in
            // Let the WindowServer remove the confirm overlay before frame 1,
            // so the selection UI can never end up inside the first capture.
            try? await Task.sleep(nanoseconds: 160_000_000)
            await self.captureOnce()
            self.showCaptureChrome()
            // Give the chrome panels a beat to register, then build the exclusion
            // list once for the whole session.
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.refreshSessionExclusion()
            guard self.isCapturing else { return }
            self.sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.captureOnce() }
            }
        }
    }

    private func refreshSessionExclusion() async {
        do {
            let content = try await ScreenshotService.shareableContent()
            sessionExclude = ScreenshotService.ownWindows(in: content)
        } catch {
            sessionExclude = []
        }
    }

    private func showCaptureChrome() {
        guard let screen = screen else { return }

        // Pass-through overlay showing the capture border.
        let borderPanel = OverlayPanel(contentRect: screen.frame, screen: screen)
        let borderView = ScrollingCaptureBorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
        borderView.screenFrame = screen.frame
        borderView.selectionGlobal = globalRect
        borderPanel.contentView = borderView
        borderPanel.ignoresMouseEvents = true
        borderPanel.orderFrontRegardless()
        panels = [borderPanel]

        // Live preview to the right of the selection.
        let previewW: CGFloat = 220
        let gap: CGFloat = 18
        var previewFrame = CGRect(
            x: globalRect.maxX + gap,
            y: globalRect.minY,
            width: previewW,
            height: globalRect.height
        )
        if previewFrame.maxX > screen.frame.maxX - 12 {
            previewFrame.origin.x = globalRect.minX - gap - previewW
        }
        previewFrame = previewFrame.intersection(screen.frame.insetBy(dx: 12, dy: 12))
        if previewFrame.width < 100 { previewFrame.size.width = 100 }

        let pPanel = OverlayPanel(contentRect: previewFrame, screen: screen)
        pPanel.setFrame(previewFrame, display: true)
        let pView = ScrollingPreviewView(frame: NSRect(origin: .zero, size: previewFrame.size))
        pPanel.contentView = pView
        pPanel.ignoresMouseEvents = true
        pPanel.orderFrontRegardless()
        previewPanel = pPanel

        // Done / Cancel — centered under the selection, clear of the capture rect.
        let barW: CGFloat = 252, barH: CGFloat = 56
        let barFrame = CGRect(
            x: globalRect.midX - barW / 2,
            y: max(screen.frame.minY + 20, globalRect.minY - barH - 44),
            width: barW,
            height: barH
        )
        let cPanel = OverlayPanel(contentRect: barFrame, screen: screen)
        cPanel.setFrame(barFrame, display: true)
        let cView = ScrollingControlsView(frame: NSRect(origin: .zero, size: barFrame.size))
        cView.onDone = { [weak self] in self?.finishDone() }
        cView.onCancel = { [weak self] in self?.finish(with: nil) }
        cPanel.contentView = cView
        cPanel.orderFrontRegardless()
        cPanel.makeKeyAndOrderFront(nil)
        controlsPanel = cPanel
    }

    private func captureOnce() async {
        guard isCapturing, !captureInFlight, let display = scDisplay else { return }
        if let s = stitchedImage, s.height >= Self.maxStitchedHeight { return }
        captureInFlight = true
        defer { captureInFlight = false }

        let local = displayLocalRect
        let scale = captureScale
        let exclude = sessionExclude
        let prev = lastFrame
        let prevRaw = lastRawFrame
        let stitched = stitchedImage
        let bPrev = bottomExclude
        let syncLost = consecutiveMisses >= Self.rebaseMissThreshold

        // Capture + detection + stitching off the main actor; results swapped in atomically.
        let outcome: StitchOutcome = await Task.detached(priority: .userInitiated) {
            guard let frame = try? await ScreenshotService.captureRegion(
                local, display: display, scale: scale, excludingWindows: exclude
            ) else { return .failed }

            guard let prev, let stitched else {
                guard let first = ImageStitcher.canonicalCopy(frame) else { return .failed }
                return .first(stitched: first, frame: frame)
            }

            switch ImageStitcher.detectScroll(previous: prev, next: frame) {
            case .scrolled(let match):
                // Fixed-footer estimate only ever grows (sticky max) so the append
                // window stays continuous across frames.
                let bNew = max(bPrev, min(match.fixedBottomRows, frame.height / 4))
                guard let merged = ImageStitcher.appendScroll(
                    stitched: stitched, newFrame: frame, scrollPixels: match.scrollPixels,
                    previousBottomExclude: bPrev, bottomExclude: bNew
                ) else { return .unchanged(frame: frame, isStationary: false) }
                return .appended(stitched: merged, frame: frame, bottomExclude: bNew)

            case .stationary:
                return .unchanged(frame: frame, isStationary: true)

            case .noMatch:
                // Sync lost (scrolled more than a viewport between ticks): once the
                // viewport settles, restart stitching from what's on screen now —
                // a content gap beats a silently dead session.
                if syncLost, let prevRaw, ImageStitcher.framesRoughlyEqual(prevRaw, frame),
                   let merged = ImageStitcher.appendFullFrame(
                       stitched: stitched, frame: frame, bottomExclude: bPrev
                   ) {
                    return .rebased(stitched: merged, frame: frame)
                }
                return .unchanged(frame: frame, isStationary: false)
            }
        }.value

        guard isCapturing else { return }
        switch outcome {
        case .first(let stitched, let frame):
            stitchedImage = stitched
            lastFrame = frame
            lastRawFrame = frame
            updatePreview()
        case .appended(let stitched, let frame, let bNew):
            stitchedImage = stitched
            lastFrame = frame
            lastRawFrame = frame
            bottomExclude = bNew
            consecutiveMisses = 0
            updatePreview()
        case .rebased(let stitched, let frame):
            stitchedImage = stitched
            lastFrame = frame
            lastRawFrame = frame
            consecutiveMisses = 0
            updatePreview()
        case .unchanged(let frame, let isStationary):
            lastRawFrame = frame
            consecutiveMisses = isStationary ? 0 : consecutiveMisses + 1
        case .failed:
            break
        }
    }

    private func updatePreview() {
        guard let image = stitchedImage,
              let view = previewPanel?.contentView as? ScrollingPreviewView else { return }
        let maxW = Int(view.bounds.width * 2)
        let maxH = Int(view.bounds.height * 2)
        let preview = ImageStitcher.previewImage(from: image, maxWidth: maxW, maxHeight: maxH) ?? image
        view.setPreview(preview, fullHeight: image.height)
    }

    // MARK: - Teardown

    /// Done: restore the withheld fixed-bottom rows (footer/chat input) once, then finish.
    private func finishDone() {
        var result = stitchedImage
        if let stitched = stitchedImage, let last = lastFrame, bottomExclude > 0 {
            result = ImageStitcher.flushBottom(stitched: stitched, lastFrame: last,
                                               bottomExclude: bottomExclude) ?? stitched
        }
        finish(with: result)
    }

    private func tearDownPanels() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        previewPanel?.orderOut(nil)
        previewPanel = nil
        controlsPanel?.orderOut(nil)
        controlsPanel = nil
    }

    private func finish(with image: CGImage?) {
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionExclude = []
        isCapturing = false
        NSCursor.arrow.set()
        tearDownPanels()
        let cb = completion
        completion = nil
        stitchedImage = nil
        lastFrame = nil
        lastRawFrame = nil
        bottomExclude = 0
        consecutiveMisses = 0
        cb?(image)
    }
}

// MARK: - Phase 1 view: drag to select

private final class ScrollingSelectionView: NSView {
    var screenFrame: CGRect = .zero
    var onConfirmed: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.35).setFill()
        bounds.fill()
        guard dragging, currentRect.width > 2, currentRect.height > 2 else { return }
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: currentRect))
        path.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.35).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let stroke = NSBezierPath(rect: currentRect)
        stroke.lineWidth = 1.5
        stroke.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        dragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let cur = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(start.x, cur.x), y: min(start.y, cur.y),
                             width: abs(cur.x - start.x), height: abs(cur.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragging = false; startPoint = nil }
        guard currentRect.width >= 20, currentRect.height >= 20 else { onCancel?(); return }
        let global = CGRect(
            x: currentRect.origin.x + screenFrame.origin.x,
            y: currentRect.origin.y + screenFrame.origin.y,
            width: currentRect.width, height: currentRect.height
        )
        onConfirmed?(global)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

// MARK: - Phase 2 view: selection + Start Capture

private final class ScrollingConfirmView: NSView {
    var screenFrame: CGRect = .zero
    var selectionGlobal: CGRect = .zero
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAdjust: ((CGRect) -> Void)?

    private var localRect: NSRect {
        NSRect(
            x: selectionGlobal.origin.x - screenFrame.origin.x,
            y: selectionGlobal.origin.y - screenFrame.origin.y,
            width: selectionGlobal.width,
            height: selectionGlobal.height
        )
    }

    private lazy var startButton: NSButton = makeStartButton()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if startButton.superview == nil {
            addSubview(startButton)
            layoutStartButton()
        }
    }

    private func makeStartButton() -> NSButton {
        let btn = NSButton(title: "", target: self, action: #selector(startTapped))
        ScrollingPillStyle.apply(to: btn, title: "Start Capture", symbol: "arrow.down.to.line.compact", variant: .light)
        return btn
    }

    private func layoutStartButton() {
        let r = localRect
        let size = ScrollingPillStyle.startCaptureSize
        startButton.frame = NSRect(
            x: r.midX - size.width / 2,
            y: r.minY - size.height - 10,
            width: size.width,
            height: size.height
        )
    }

    @objc private func startTapped() { onStart?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = localRect
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: r))
        path.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.45).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let stroke = NSBezierPath(rect: r)
        stroke.lineWidth = 1.5
        stroke.stroke()
        drawHandles(in: r)
        layoutStartButton()
    }

    private func drawHandles(in r: NSRect) {
        NSColor.white.setFill()
        let s: CGFloat = 7
        for pt in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                   CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                   CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)] {
            NSBezierPath(ovalIn: NSRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)).fill()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 { onStart?() }
        else { super.keyDown(with: event) }
    }
}

// MARK: - Phase 3: pass-through border

private final class ScrollingCaptureBorderView: NSView {
    var screenFrame: CGRect = .zero
    var selectionGlobal: CGRect = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(
            x: selectionGlobal.origin.x - screenFrame.origin.x,
            y: selectionGlobal.origin.y - screenFrame.origin.y,
            width: selectionGlobal.width,
            height: selectionGlobal.height
        )
        // Everything here is drawn strictly OUTSIDE the capture region, so the
        // chrome can never bleed into a frame even if window exclusion races.
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: r))
        outside.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.22).setFill()
        outside.fill()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let stroke = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2))
        stroke.lineWidth = 2.5
        stroke.stroke()
    }
}

// MARK: - Live preview panel

private final class ScrollingPreviewView: NSView {
    private var previewImage: CGImage?
    private var fullPixelHeight: Int = 0

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    func setPreview(_ image: CGImage, fullHeight: Int) {
        previewImage = image
        fullPixelHeight = fullHeight
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Card background with padding around the thumbnail.
        let outer = bounds.insetBy(dx: 10, dy: 10)
        NSColor(white: 0.11, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: outer, xRadius: 12, yRadius: 12).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        NSBezierPath(roundedRect: outer, xRadius: 12, yRadius: 12).lineWidth = 0.5
        NSBezierPath(roundedRect: outer, xRadius: 12, yRadius: 12).stroke()

        guard let img = previewImage else { return }
        let inset = outer.insetBy(dx: 10, dy: 10)
        var draw = inset
        let imgAspect = CGFloat(img.width) / CGFloat(img.height)
        let boxAspect = inset.width / inset.height
        if imgAspect > boxAspect {
            draw.size.height = inset.width / imgAspect
            draw.origin.y = inset.minY + (inset.height - draw.height) / 2
        } else {
            draw.size.width = inset.height * imgAspect
            draw.origin.x = inset.minX + (inset.width - draw.width) / 2
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8).addClip()
        NSColor(white: 0.06, alpha: 1).setFill()
        NSBezierPath(rect: inset).fill()
        img.draw(in: draw)
        NSGraphicsContext.restoreGraphicsState()

        let label = "\(fullPixelHeight) px tall"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65)
        ]
        (label as NSString).draw(at: NSPoint(x: outer.minX + 12, y: outer.maxY - 18), withAttributes: attrs)
    }
}

private extension CGImage {
    func draw(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(self, in: rect)
    }
}

// MARK: - Pill button styling (explicit colors — overlay panels inherit dark appearance)

private enum ScrollingPillStyle {
    enum Variant { case light, dark }

    static let startCaptureSize = NSSize(width: 176, height: 36)
    private static let controlSize = NSSize(width: 108, height: 36)

    static func apply(to button: NSButton, title: String, symbol: String, variant: Variant) {
        let textColor: NSColor = variant == .light
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor.white
        let background: NSColor = variant == .light
            ? NSColor(calibratedWhite: 0.96, alpha: 1)
            : NSColor(calibratedWhite: 0.18, alpha: 0.96)

        button.title = ""
        button.bezelStyle = .rounded
        button.isBordered = false
        button.imagePosition = .imageLeading
        // Keep the symbol glued to the label — without this, a borderless button
        // pins the image to its leading edge while the title stays centered.
        button.imageHugsTitle = true
        button.appearance = NSAppearance(named: .aqua)
        button.wantsLayer = true
        button.layer?.backgroundColor = background.cgColor
        button.layer?.cornerRadius = 18
        button.layer?.borderWidth = 0.5
        button.layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.16
        button.layer?.shadowRadius = 5
        button.layer?.shadowOffset = CGSize(width: 0, height: -2)

        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.attributedTitle = NSAttributedString(
            string: " \(title) ",
            attributes: [.font: font, .foregroundColor: textColor]
        )

        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [textColor]))
            button.image = base.withSymbolConfiguration(config)
        }
    }

    static func makeControl(title: String, symbol: String, variant: Variant, target: AnyObject?, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: target, action: action)
        apply(to: btn, title: title, symbol: symbol, variant: variant)
        return btn
    }
}

// MARK: - Done / Cancel bar

private final class ScrollingControlsView: NSView {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private var cancelButton: NSButton!
    private var doneButton: NSButton!

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if cancelButton == nil {
            cancelButton = ScrollingPillStyle.makeControl(
                title: "Cancel", symbol: "xmark", variant: .dark,
                target: self, action: #selector(cancelTapped)
            )
            doneButton = ScrollingPillStyle.makeControl(
                title: "Done", symbol: "checkmark", variant: .light,
                target: self, action: #selector(doneTapped)
            )
            addSubview(cancelButton)
            addSubview(doneButton)
        }
        layoutButtons()
    }

    override func layout() {
        super.layout()
        layoutButtons()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle backing card so the controls read clearly over any content.
        let card = bounds.insetBy(dx: 4, dy: 6)
        NSColor(white: 0.08, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
    }

    private func layoutButtons() {
        guard cancelButton != nil, doneButton != nil else { return }
        let gap: CGFloat = 12
        let size = NSSize(width: 108, height: 36)
        let totalW = size.width * 2 + gap
        let originX = (bounds.width - totalW) / 2
        let originY = (bounds.height - size.height) / 2
        cancelButton.frame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
        doneButton.frame = NSRect(x: originX + size.width + gap, y: originY, width: size.width, height: size.height)
    }

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 { onDone?() }
        else { super.keyDown(with: event) }
    }
}
