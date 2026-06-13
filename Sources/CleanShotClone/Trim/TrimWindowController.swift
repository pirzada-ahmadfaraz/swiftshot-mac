import AppKit
import AVFoundation
import AVKit

enum MediaKind {
    case video, gif

    var fileExtension: String { self == .video ? "mp4" : "gif" }
}

/// Trim editor for recordings — video (MP4) and GIF.
///
/// Preview on top, filmstrip with draggable yellow in/out handles below,
/// Trim / Cancel on the right. Video trims are passthrough (lossless, fast,
/// cuts snap to keyframes); GIFs are re-encoded frame-exact.
@MainActor
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private let url: URL
    private let kind: MediaKind
    private let onTrimmed: (URL) -> Void
    private var retainSelf: TrimWindowController?

    private var player: AVPlayer?
    private var playerTimeObserver: Any?
    private var duration: Double = 0
    private let trimBar = TrimBarView()
    private var trimButton: NSButton!
    private var playButton: NSButton?

    init(url: URL, kind: MediaKind, onTrimmed: @escaping (URL) -> Void) {
        self.url = url
        self.kind = kind
        self.onTrimmed = onTrimmed

        let size = NSSize(width: 760, height: 470)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = kind == .video ? "Trim Video" : "Trim GIF"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        window.delegate = self

        buildUI(in: window, size: size)
        loadMedia()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        retainSelf = self
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let obs = playerTimeObserver { player?.removeTimeObserver(obs) }
        playerTimeObserver = nil
        player?.pause()
        retainSelf = nil
    }

    // MARK: - UI

    private func buildUI(in window: NSWindow, size: NSSize) {
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor

        let previewFrame = NSRect(x: 16, y: 116, width: size.width - 32, height: size.height - 132)
        switch kind {
        case .video:
            let player = AVPlayer(url: url)
            self.player = player
            let playerView = AVPlayerView(frame: previewFrame)
            playerView.player = player
            playerView.controlsStyle = .none
            playerView.autoresizingMask = [.width, .height]
            content.addSubview(playerView)
        case .gif:
            let imageView = NSImageView(frame: previewFrame)
            imageView.image = NSImage(contentsOf: url)
            imageView.animates = true
            imageView.imageScaling = .scaleProportionallyDown
            imageView.autoresizingMask = [.width, .height]
            content.addSubview(imageView)
        }

        // Play button (video only — GIFs animate continuously).
        var stripX: CGFloat = 16
        if kind == .video {
            let play = NSButton(title: "", target: self, action: #selector(playTapped))
            play.isBordered = false
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            play.frame = NSRect(x: 20, y: 36, width: 44, height: 44)
            content.addSubview(play)
            playButton = play
            stripX = 76
        }

        trimBar.frame = NSRect(x: stripX, y: 24, width: size.width - stripX - 116, height: 68)
        content.addSubview(trimBar)

        trimButton = pillButton(title: "Trim", prominent: true, action: #selector(trimTapped))
        trimButton.frame = NSRect(x: size.width - 100, y: 62, width: 84, height: 30)
        content.addSubview(trimButton)

        let cancel = pillButton(title: "Cancel", prominent: false, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: size.width - 100, y: 26, width: 84, height: 30)
        content.addSubview(cancel)

        window.contentView = content
    }

    private func pillButton(title: String, prominent: Bool, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        if prominent { btn.keyEquivalent = "\r" }
        return btn
    }

    // MARK: - Media loading

    private func loadMedia() {
        switch kind {
        case .gif:
            duration = GIFFile.totalDuration(of: url)
            trimBar.configure(duration: duration)
            let thumbs = GIFFile.thumbnails(of: url, count: 9, maxHeight: 56)
            trimBar.setThumbnails(thumbs)
        case .video:
            let asset = AVURLAsset(url: url)
            Task { @MainActor in
                let duration = (try? await asset.load(.duration))?.seconds ?? 0
                self.duration = duration
                self.trimBar.configure(duration: duration)
                self.generateVideoThumbnails(asset: asset, duration: duration)
            }
        }
    }

    private func generateVideoThumbnails(asset: AVAsset, duration: Double) {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: 120)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let count = 9
        let times = (0..<count).map {
            NSValue(time: CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600))
        }
        var images = [CGImage?](repeating: nil, count: count)
        var done = 0
        generator.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, _, _ in
            let index = times.firstIndex { $0.timeValue == requested } ?? 0
            images[index] = image
            done += 1
            if done == count {
                let final = images.compactMap { $0 }
                Task { @MainActor in self.trimBar.setThumbnails(final) }
            }
        }
    }

    // MARK: - Playback preview

    @objc private func playTapped() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            setPlayIcon(playing: false)
            return
        }
        let start = CMTime(seconds: trimBar.trimStart, preferredTimescale: 600)
        let end = trimBar.trimEnd
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        setPlayIcon(playing: true)

        if let obs = playerTimeObserver { player.removeTimeObserver(obs) }
        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            if time.seconds >= end {
                Task { @MainActor in
                    self.player?.pause()
                    self.setPlayIcon(playing: false)
                }
            }
        }
    }

    private func setPlayIcon(playing: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        playButton?.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(config)
    }

    // MARK: - Trim / cancel

    @objc private func cancelTapped() {
        close()
    }

    @objc private func trimTapped() {
        let start = trimBar.trimStart
        let end = trimBar.trimEnd
        guard end - start > 0.05, duration > 0 else { return }

        trimButton.isEnabled = false
        trimButton.title = "Trimming…"

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trimmed-\(UUID().uuidString).\(kind.fileExtension)")

        switch kind {
        case .gif:
            let source = url
            Task.detached(priority: .userInitiated) {
                let ok = GIFFile.trim(source, from: start, to: end, output: output)
                await MainActor.run { [weak self] in self?.exportFinished(ok ? output : nil) }
            }
        case .video:
            exportVideo(from: start, to: end, output: output)
        }
    }

    private func exportVideo(from start: Double, to end: Double, output: URL) {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            exportFinished(nil)
            return
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        session.exportAsynchronously { [weak self] in
            Task { @MainActor in
                if session.status == .completed {
                    self?.exportFinished(output)
                } else {
                    // Passthrough can fail on some streams — retry with a re-encode.
                    self?.exportVideoReencode(from: start, to: end, output: output)
                }
            }
        }
    }

    private func exportVideoReencode(from start: Double, to end: Double, output: URL) {
        let asset = AVURLAsset(url: url)
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            exportFinished(nil)
            return
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        session.exportAsynchronously { [weak self] in
            Task { @MainActor in
                self?.exportFinished(session.status == .completed ? output : nil)
            }
        }
    }

    private func exportFinished(_ output: URL?) {
        trimButton.isEnabled = true
        trimButton.title = "Trim"
        guard let output else {
            let alert = NSAlert()
            alert.messageText = "Trim failed"
            alert.informativeText = "The media could not be trimmed."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        let cb = onTrimmed
        close()
        cb(output)
    }
}

// MARK: - Filmstrip with yellow trim handles

private final class TrimBarView: NSView {
    private(set) var trimStart: Double = 0
    private(set) var trimEnd: Double = 0
    private var duration: Double = 0
    private var thumbnails: [CGImage] = []

    private enum Dragging { case none, left, right, range }
    private var dragging: Dragging = .none
    private var dragAnchor: CGFloat = 0
    private var rangeAtDragStart: (Double, Double) = (0, 0)

    private let handleW: CGFloat = 12

    func configure(duration: Double) {
        self.duration = max(duration, 0.01)
        trimStart = 0
        trimEnd = self.duration
        needsDisplay = true
    }

    func setThumbnails(_ thumbs: [CGImage]) {
        thumbnails = thumbs
        needsDisplay = true
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var stripRect: NSRect {
        bounds.insetBy(dx: handleW, dy: 6)
    }

    private func x(for t: Double) -> CGFloat {
        stripRect.minX + CGFloat(t / duration) * stripRect.width
    }

    private func time(for x: CGFloat) -> Double {
        Double((x - stripRect.minX) / stripRect.width) * duration
    }

    override func draw(_ dirtyRect: NSRect) {
        let strip = stripRect

        // Thumbnails
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: strip, xRadius: 8, yRadius: 8).addClip()
        NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
        strip.fill()
        if !thumbnails.isEmpty {
            let w = strip.width / CGFloat(thumbnails.count)
            for (i, thumb) in thumbnails.enumerated() {
                let rect = NSRect(x: strip.minX + CGFloat(i) * w, y: strip.minY, width: w, height: strip.height)
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.draw(thumb, in: rect)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard duration > 0 else { return }
        let xs = x(for: trimStart)
        let xe = x(for: trimEnd)

        // Dim outside the kept range
        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        if xs > strip.minX {
            NSRect(x: strip.minX, y: strip.minY, width: xs - strip.minX, height: strip.height).fill()
        }
        if xe < strip.maxX {
            NSRect(x: xe, y: strip.minY, width: strip.maxX - xe, height: strip.height).fill()
        }

        // Yellow frame + handles
        let frame = NSRect(x: xs - handleW, y: strip.minY - 3, width: xe - xs + handleW * 2, height: strip.height + 6)
        let framePath = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        framePath.append(NSBezierPath(roundedRect: NSRect(x: xs, y: strip.minY, width: xe - xs, height: strip.height), xRadius: 2, yRadius: 2).reversed)
        NSColor.systemYellow.setFill()
        framePath.fill()

        // Handle grips
        NSColor(calibratedWhite: 0.25, alpha: 0.9).setFill()
        for hx in [xs - handleW / 2, xe + handleW / 2] {
            NSRect(x: hx - 1, y: frame.midY - 8, width: 2, height: 16).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let xs = x(for: trimStart)
        let xe = x(for: trimEnd)
        if abs(p.x - (xs - handleW / 2)) <= handleW { dragging = .left }
        else if abs(p.x - (xe + handleW / 2)) <= handleW { dragging = .right }
        else if p.x > xs, p.x < xe { dragging = .range; dragAnchor = p.x; rangeAtDragStart = (trimStart, trimEnd) }
        else { dragging = .none }
    }

    override func mouseDragged(with event: NSEvent) {
        guard duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let minSpan = min(0.2, duration / 2)
        switch dragging {
        case .left:
            trimStart = min(max(0, time(for: p.x)), trimEnd - minSpan)
        case .right:
            trimEnd = max(min(duration, time(for: p.x)), trimStart + minSpan)
        case .range:
            let dt = time(for: p.x) - time(for: dragAnchor)
            let span = rangeAtDragStart.1 - rangeAtDragStart.0
            var s = rangeAtDragStart.0 + dt
            s = min(max(0, s), duration - span)
            trimStart = s
            trimEnd = s + span
        case .none:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = .none
    }
}
