import AppKit
import ScreenCaptureKit

/// One active recording: owns the recorder (video or GIF), the on-screen chrome
/// (region border + stop/pause/trash bar), and the optional in-recording overlays
/// (webcam bubble, click ripples, keystroke pills).
///
/// Capture exclusion is selective: the border and the controls bar are excluded
/// from the recording; the webcam bubble and input overlays are deliberately
/// captured — they're part of the content the user wants.
@MainActor
final class RecordingSession {
    private let setup: RecordingSetupResult
    private let settings: RecordingSettings

    private let videoRecorder = ScreenRecorder()
    private let gifRecorder = GIFRecorder()
    private let webcam = WebcamOverlay()
    private let clicks = ClickHighlighter()
    private let keystrokes = KeystrokeOverlay()
    private var annotation: AnnotationController?

    private var borderPanel: OverlayPanel?
    private var controlsPanel: OverlayPanel?
    private var controlsView: RecordingControlsView?

    // Captured at start so the annotation toolbar can be excluded mid-recording.
    private var scDisplay: SCDisplay?
    private var baseExcluded: [SCWindow] = []

    private var timer: Timer?
    private var startedAt: Date?
    private var accumulatedPause: TimeInterval = 0
    private var pausedAt: Date?
    private(set) var isPaused = false
    private var finishing = false

    /// nil URL = discarded or failed. Error is set when save/stop failed.
    var onFinished: ((URL?, RecordingMode, Error?) -> Void)?
    /// Elapsed string for the menu bar (nil when the session ends).
    var onElapsed: ((String?) -> Void)?

    init(setup: RecordingSetupResult, settings: RecordingSettings) {
        self.setup = setup
        self.settings = settings
    }

    func start() async throws {
        DoNotDisturbController.enableIfNeeded(settings.doNotDisturbWhileRecording)

        let content = try await ScreenshotService.shareableContent()
        guard let display = Coords.scDisplay(for: setup.screen, in: content) else {
            DoNotDisturbController.restore()
            throw NSError(domain: "RecordingSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Display not found"])
        }
        let localRect = Coords.toDisplayLocal(setup.globalRect, on: setup.screen)

        // Resolve AV permissions up front — awaiting the user's answer here means
        // a denied/missing permission downgrades the session instead of crashing
        // it (TCC aborts the process on unguarded access).
        var micAllowed = false
        if setup.mode == .video, settings.captureMicrophone {
            micAllowed = await AVPermission.ensureMicrophone()
            if !micAllowed { Log.error("Microphone not authorized — recording without mic", log: Log.recording) }
        }
        var camAllowed = false
        if settings.webcamEnabled {
            camAllowed = await AVPermission.ensureCamera()
            if !camAllowed { Log.error("Camera not authorized — recording without webcam overlay", log: Log.recording) }
        }

        // Webcam first (not excluded → it gets recorded).
        if camAllowed {
            webcam.show(in: setup.globalRect, shape: settings.webcamShape, size: settings.webcamSize)
        }

        // Chrome (excluded from the recording).
        showBorder()
        if settings.showControlsWhileRecording { showControlsBar() }

        do {
            // Give the WindowServer a beat to register the chrome, then snapshot the
            // exclusion list: ONLY the chrome windows, never the webcam/overlays.
            try? await Task.sleep(nanoseconds: 250_000_000)
            let chromeNumbers = Set(
                [borderPanel?.windowNumber, controlsPanel?.windowNumber]
                    .compactMap { $0 }
                    .map { CGWindowID($0) }
            )
            let freshContent = (try? await ScreenshotService.shareableContent()) ?? content
            let myPID = ProcessInfo.processInfo.processIdentifier
            let excluded = freshContent.windows.filter {
                $0.owningApplication?.processID == myPID && chromeNumbers.contains($0.windowID)
            }
            self.scDisplay = display
            self.baseExcluded = excluded

            let handleStreamError: (Error) -> Void = { [weak self] error in
                Task { @MainActor in self?.failRecording(with: error) }
            }

            switch setup.mode {
            case .video:
                var options = ScreenRecorder.Options()
                options.sourceRect = localRect
                options.scale = settings.scaleRetinaTo1x ? 1 : setup.screen.backingScaleFactor
                options.fps = settings.videoFPS
                options.showsCursor = settings.showCursor
                options.captureSystemAudio = settings.captureSystemAudio
                options.captureMicrophone = micAllowed
                options.excludingWindows = excluded
                let outputURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Recording-\(UUID().uuidString).mp4")
                videoRecorder.onStreamError = handleStreamError
                try await videoRecorder.start(display: display, options: options, outputURL: outputURL)
            case .gif:
                var options = GIFRecorder.Options()
                options.sourceRect = localRect
                options.scale = settings.gifCaptureAt1x ? 1 : setup.screen.backingScaleFactor
                options.fps = settings.gifFPS
                options.showsCursor = settings.showCursor
                options.excludingWindows = excluded
                gifRecorder.onStreamError = handleStreamError
                try await gifRecorder.start(display: display, options: options)
            }

            if settings.highlightClicks { clicks.start() }
            if settings.showKeystrokes { keystrokes.start(regionGlobal: setup.globalRect) }

            startedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            tearDownChrome()
            DoNotDisturbController.restore()
            throw error
        }
    }

    // MARK: - Controls

    func togglePause() {
        guard !finishing else { return }
        isPaused.toggle()
        if isPaused {
            pausedAt = Date()
            setup.mode == .video ? videoRecorder.pause() : gifRecorder.pause()
        } else {
            if let p = pausedAt { accumulatedPause += Date().timeIntervalSince(p) }
            pausedAt = nil
            setup.mode == .video ? videoRecorder.resume() : gifRecorder.resume()
        }
        controlsView?.setPaused(isPaused)
    }

    func stopAndSave() {
        guard !finishing else { return }
        finishing = true
        Task { @MainActor in
            self.tearDownChrome()
            DoNotDisturbController.restore()
            var url: URL?
            var saveError: Error?
            do {
                switch self.setup.mode {
                case .video: url = try await self.videoRecorder.stop()
                case .gif: url = try await self.gifRecorder.stop()
                }
            } catch {
                saveError = error
                Log.error("Recording stop failed: \(error)", log: Log.recording)
            }
            self.onFinished?(url, self.setup.mode, saveError)
        }
    }

    func discard() {
        guard !finishing else { return }
        finishing = true
        Task { @MainActor in
            self.tearDownChrome()
            DoNotDisturbController.restore()
            switch self.setup.mode {
            case .video:
                await self.videoRecorder.cancel()
            case .gif:
                await self.gifRecorder.discard()
            }
            self.onFinished?(nil, self.setup.mode, nil)
        }
    }

    private func failRecording(with error: Error) {
        guard !finishing else { return }
        finishing = true
        tearDownChrome()
        DoNotDisturbController.restore()
        Task { @MainActor in
            switch self.setup.mode {
            case .video: await self.videoRecorder.cancel()
            case .gif: await self.gifRecorder.discard()
            }
            self.onFinished?(nil, self.setup.mode, error)
        }
    }

    // MARK: - Timer

    private func tick() {
        guard let startedAt, !finishing else { return }
        let pausedExtra = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        let elapsed = Date().timeIntervalSince(startedAt) - accumulatedPause - pausedExtra
        let text = Self.format(elapsed)
        controlsView?.setElapsed(text)
        if settings.displayTimeInMenuBar { onElapsed?(text) }
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Chrome

    private func showBorder() {
        let screen = setup.screen
        let panel = OverlayPanel(contentRect: screen.frame, screen: screen)
        let view = RecordingBorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.screenFrame = screen.frame
        view.selectionGlobal = setup.globalRect
        panel.contentView = view
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        borderPanel = panel
    }

    private func showControlsBar() {
        let screen = setup.screen
        let size = RecordingControlsView.barSize
        var origin = CGPoint(
            x: setup.globalRect.midX - size.width / 2,
            y: setup.globalRect.minY - size.height - 16
        )
        if origin.y < screen.visibleFrame.minY + 8 {
            origin.y = setup.globalRect.maxY + 16
        }
        origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)

        let panel = OverlayPanel(contentRect: CGRect(origin: origin, size: size), screen: screen)
        // Above the annotation drawing overlay so Stop/Pause/Trash stay clickable
        // even while annotate mode covers the (often near-fullscreen) region.
        panel.level = AnnotationController.chromeLevel
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        let view = RecordingControlsView(frame: NSRect(origin: .zero, size: size))
        view.onStop = { [weak self] in self?.stopAndSave() }
        view.onPause = { [weak self] in self?.togglePause() }
        view.onAnnotate = { [weak self] in self?.toggleAnnotation() }
        view.onTrash = { [weak self] in self?.discard() }
        panel.contentView = view
        panel.orderFrontRegardless()
        controlsPanel = panel
        controlsView = view
    }

    // MARK: - Annotation

    private func toggleAnnotation() {
        guard !finishing else { return }
        if annotation == nil {
            let controller = AnnotationController(regionGlobal: setup.globalRect, screen: setup.screen)
            controller.onToolbarShown = { [weak self] panel in self?.excludeFromRecording(panel) }
            // Drives the pencil-button highlight for BOTH the bar toggle and the
            // toolbar's Done button, so the two can never get out of sync.
            controller.onActiveChanged = { [weak self] active in
                guard let self else { return }
                self.controlsView?.setAnnotating(active)
                self.controlsPanel?.orderFrontRegardless()
                // While drawing, suspend click ripples / keystroke pills — every
                // click would otherwise spawn a yellow ripple over the annotation
                // canvas and tools. Resume them (if enabled) when annotate exits.
                if active {
                    self.clicks.stop()
                    self.keystrokes.stop()
                } else {
                    if self.settings.highlightClicks { self.clicks.start() }
                    if self.settings.showKeystrokes { self.keystrokes.start(regionGlobal: self.setup.globalRect) }
                }
            }
            annotation = controller
        }
        annotation?.toggle()
    }

    /// Add a chrome window to the live capture filter so it can't leak into the
    /// recording (the toolbar is also placed outside the region for good measure).
    private func excludeFromRecording(_ panel: NSPanel) {
        guard let display = scDisplay else { return }
        Task { @MainActor in
            guard let content = try? await ScreenshotService.shareableContent() else { return }
            let myPID = ProcessInfo.processInfo.processIdentifier
            let extra = content.windows.filter {
                $0.owningApplication?.processID == myPID && $0.windowID == CGWindowID(panel.windowNumber)
            }
            let filter = SCContentFilter(display: display, excludingWindows: baseExcluded + extra)
            switch setup.mode {
            case .video: await videoRecorder.updateContentFilter(filter)
            case .gif: await gifRecorder.updateContentFilter(filter)
            }
        }
    }

    private func tearDownChrome() {
        timer?.invalidate()
        timer = nil
        clicks.stop()
        keystrokes.stop()
        webcam.hide()
        annotation?.tearDown()
        annotation = nil
        borderPanel?.orderOut(nil)
        borderPanel = nil
        controlsPanel?.orderOut(nil)
        controlsPanel = nil
        controlsView = nil
        onElapsed?(nil)
    }
}

// MARK: - Border (pass-through, drawn strictly outside the recorded region)

private final class RecordingBorderView: NSView {
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
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        let stroke = NSBezierPath(rect: r.insetBy(dx: -2, dy: -2))
        stroke.lineWidth = 2.5
        stroke.stroke()
    }
}

// MARK: - Controls bar: ⏹ red + time | ⏸ | 🗑

private final class RecordingControlsView: NSView {
    static let barSize = NSSize(width: 258, height: 52)

    var onStop: (() -> Void)?
    var onPause: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onTrash: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var pauseButton: NSButton!
    private var annotateButton: NSButton!
    private var dragStartGlobal: NSPoint = .zero
    private var baseOrigin: NSPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.96).cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        let stop = symbolButton("stop.circle.fill", color: .systemRed, size: 21, action: #selector(stopTapped))
        stop.frame = NSRect(x: 14, y: 13, width: 26, height: 26)
        addSubview(stop)

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .systemRed
        timeLabel.frame = NSRect(x: 44, y: 17, width: 48, height: 18)
        addSubview(timeLabel)

        addDivider(x: 98)

        pauseButton = symbolButton("pause.circle", color: .white, size: 21, action: #selector(pauseTapped))
        pauseButton.frame = NSRect(x: 110, y: 13, width: 26, height: 26)
        addSubview(pauseButton)

        addDivider(x: 148)

        annotateButton = symbolButton("pencil.tip.crop.circle", color: .white, size: 20, action: #selector(annotateTapped))
        annotateButton.frame = NSRect(x: 160, y: 11, width: 30, height: 30)
        annotateButton.wantsLayer = true
        annotateButton.layer?.cornerRadius = 8
        annotateButton.toolTip = "Annotate"
        addSubview(annotateButton)

        addDivider(x: 200)

        let trash = symbolButton("trash", color: .white, size: 17, action: #selector(trashTapped))
        trash.frame = NSRect(x: 214, y: 13, width: 26, height: 26)
        addSubview(trash)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setElapsed(_ text: String) { timeLabel.stringValue = text }

    func setPaused(_ paused: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        pauseButton.image = NSImage(
            systemSymbolName: paused ? "play.circle" : "pause.circle",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)
    }

    /// Reflect annotate-mode on/off on the pencil button.
    func setAnnotating(_ on: Bool) {
        annotateButton.layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [on ? .white : NSColor.white.withAlphaComponent(0.9)]))
        annotateButton.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func symbolButton(_ symbol: String, color: NSColor, size: CGFloat, action: Selector) -> NSButton {
        // FirstMouseButton: this bar is a non-activating panel, so a plain NSButton
        // would swallow the first click just to focus the window. That was the
        // "annotate button does nothing" bug — the overlay had taken key focus.
        let btn = FirstMouseButton(title: "", target: self, action: action)
        btn.isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        return btn
    }

    private func addDivider(x: CGFloat) {
        let v = NSView(frame: NSRect(x: x, y: 10, width: 1, height: 32))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        addSubview(v)
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func pauseTapped() { onPause?() }
    @objc private func annotateTapped() { onAnnotate?() }
    @objc private func trashTapped() { onTrash?() }

    // Drag the bar anywhere (background only — buttons swallow their own events).
    override func mouseDown(with event: NSEvent) {
        dragStartGlobal = NSEvent.mouseLocation
        baseOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let g = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: baseOrigin.x + (g.x - dragStartGlobal.x),
            y: baseOrigin.y + (g.y - dragStartGlobal.y)
        ))
    }
}
