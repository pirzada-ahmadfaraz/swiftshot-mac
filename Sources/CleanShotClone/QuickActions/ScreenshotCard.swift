import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Borderless floating panel that hosts one screenshot card.
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// AppKit view that draws the screenshot (rounded, aspect-fill, downsampled for
/// smooth compositing) and handles directional gestures: drag LEFT to dismiss,
/// drag RIGHT to drag the image out into another app. A SwiftUI overlay supplies
/// the hover buttons.
final class CardView: NSView, NSDraggingSource {
    private let fullImage: CGImage          // full-resolution, used for drag-out / actions
    private let nsImage: NSImage
    let model: CardModel

    /// Called when the card should be dismissed (swiped left past threshold, or X tapped).
    var onClose: (() -> Void)?

    /// Media cards drag out the actual recording file instead of a temp PNG.
    var dragFileURL: URL?

    private var imageLayer: CALayer!
    private var hostingView: NSHostingView<CardButtonsOverlay>!
    private var trackingArea: NSTrackingArea?

    private var dragStartInWindow: NSPoint?
    private var dragStartGlobal: NSPoint = .zero
    private var baseOrigin: NSPoint = .zero
    private enum Decision { case undecided, closing, draggingOut, ignored }
    private var decision: Decision = .undecided
    private var isGesturing = false
    private let pinned: Bool
    private var pendingDragURL: URL?

    private let cornerRadius: CGFloat = 12
    private let closeThreshold: CGFloat = 60

    init(frame: NSRect, cgImage: CGImage, model: CardModel, pinned: Bool = false) {
        self.fullImage = cgImage
        self.nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        self.model = model
        self.pinned = pinned
        model.pinned = pinned
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = false

        // Downsample to ~2x the card size so the layer texture is tiny (this is what
        // keeps dragging smooth — a full 5K screenshot as a layer texture is huge).
        let display = Self.downsample(cgImage, to: frame.size, scale: 2)

        imageLayer = CALayer()
        imageLayer.frame = bounds
        imageLayer.contents = display
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.cornerRadius = cornerRadius
        imageLayer.masksToBounds = true
        imageLayer.borderWidth = 0.5
        imageLayer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.addSublayer(imageLayer)

        hostingView = NSHostingView(rootView: CardButtonsOverlay(model: model))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { if !isGesturing && !pinned { model.hovering = true } }
    override func mouseExited(with event: NSEvent) { if !isGesturing && !pinned { model.hovering = false } }

    // MARK: - Directional gesture

    override func mouseDown(with event: NSEvent) {
        dragStartInWindow = event.locationInWindow
        dragStartGlobal = NSEvent.mouseLocation
        baseOrigin = window?.frame.origin ?? .zero
        decision = .undecided
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartInWindow, let window else { return }

        // Pinned cards reposition the window instead of swiping/dragging-out.
        if pinned {
            let g = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(
                x: baseOrigin.x + (g.x - dragStartGlobal.x),
                y: baseOrigin.y + (g.y - dragStartGlobal.y)
            ))
            return
        }

        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y

        if decision == .undecided {
            guard abs(dx) > 6 || abs(dy) > 6 else { return }
            if abs(dx) >= abs(dy) {
                decision = dx > 0 ? .draggingOut : .closing
                isGesturing = true
                model.hovering = false
            } else {
                decision = .ignored
            }
            if decision == .draggingOut {
                beginImageDrag(with: event)
                return
            }
        }

        if decision == .closing {
            let clampedDX = min(dx, 0)
            window.setFrameOrigin(NSPoint(x: baseOrigin.x + clampedDX, y: baseOrigin.y))
            window.alphaValue = max(0.15, 1 + clampedDX / 200)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { decision = .undecided; dragStartInWindow = nil; isGesturing = false }
        guard !pinned else { return }
        guard let start = dragStartInWindow, let window else { return }
        let dx = event.locationInWindow.x - start.x

        if decision == .closing {
            if dx < -closeThreshold {
                onClose?()
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    window.animator().setFrameOrigin(baseOrigin)
                    window.animator().alphaValue = 1
                }
            }
        }
    }

    // MARK: - Drag out

    private func beginImageDrag(with event: NSEvent) {
        // Media card: drag the recording file itself.
        if let fileURL = dragFileURL {
            let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
            item.setDraggingFrame(bounds, contents: nsImage)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            return
        }

        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Screenshot-\(UUID().uuidString).png")
        do { try png.write(to: url) } catch { return }
        pendingDragURL = url

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: imageLayer.contents.map { _ in nsImage } ?? nsImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let url = pendingDragURL {
            try? FileManager.default.removeItem(at: url)
            pendingDragURL = nil
        }
    }

    // MARK: - Downsample

    private static func downsample(_ image: CGImage, to size: NSSize, scale: CGFloat) -> CGImage {
        let w = max(Int(size.width * scale), 1)
        let h = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high

        // Aspect-fill: scale the source so it covers the card, centered (cropping overflow).
        let imgAspect = CGFloat(image.width) / CGFloat(image.height)
        let dstAspect = CGFloat(w) / CGFloat(h)
        var drawRect: CGRect
        if imgAspect > dstAspect {
            let scaledW = CGFloat(h) * imgAspect
            drawRect = CGRect(x: (CGFloat(w) - scaledW) / 2, y: 0, width: scaledW, height: CGFloat(h))
        } else {
            let scaledH = CGFloat(w) / imgAspect
            drawRect = CGRect(x: 0, y: (CGFloat(h) - scaledH) / 2, width: CGFloat(w), height: scaledH)
        }
        ctx.draw(image, in: drawRect)
        return ctx.makeImage() ?? image
    }
}

/// Owns one card's panel and exposes layout/animation helpers to the stacking manager.
@MainActor
final class ScreenshotCardController {
    /// Universal card size — identical for every screenshot regardless of shape.
    static let cardSize = NSSize(width: 244, height: 152)

    var size: NSSize { Self.cardSize }
    let panel: CardPanel
    private let cardView: CardView
    private let model: CardModel

    var onRequestClose: ((ScreenshotCardController) -> Void)?

    init(
        image: CGImage,
        pinAtGlobalRect: CGRect? = nil,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onPin: @escaping (CGRect) -> Void,
        onEdit: @escaping () -> Void,
        onCloud: @escaping () -> Void,
        onRedact: @escaping () -> Void
    ) {
        let size = Self.cardSize
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let model = CardModel(image: nsImage, horizontalActions: true)
        self.model = model

        let view = CardView(frame: NSRect(origin: .zero, size: size), cgImage: image, model: model)
        self.cardView = view

        let panel = CardPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        self.panel = panel

        model.onCopy = { [weak self] in onCopy(); self?.requestClose() }
        model.onSave = { [weak self] in onSave(); self?.requestClose() }
        model.onEdit = { [weak self] in onEdit(); self?.requestClose() }
        model.onCloud = onCloud
        model.onRedact = onRedact
        model.onPin = { [weak self] in
            let rect = pinAtGlobalRect ?? panel.frame
            onPin(rect)
            self?.requestClose()
        }
        model.onClose = { [weak self] in self?.requestClose() }
        view.onClose = { [weak self] in self?.requestClose() }
    }

    /// Media flavor: video/GIF recording. Trim replaces Edit (scissors), no pin,
    /// drag-out hands over the actual file.
    init(
        mediaThumbnail: CGImage,
        mediaURL: URL,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onTrim: @escaping () -> Void
    ) {
        let size = Self.cardSize
        let nsImage = NSImage(cgImage: mediaThumbnail, size: NSSize(width: mediaThumbnail.width, height: mediaThumbnail.height))
        let model = CardModel(image: nsImage, horizontalActions: true)
        model.isMedia = true
        self.model = model

        let view = CardView(frame: NSRect(origin: .zero, size: size), cgImage: mediaThumbnail, model: model)
        view.dragFileURL = mediaURL
        self.cardView = view

        let panel = CardPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        self.panel = panel

        model.onCopy = { [weak self] in onCopy(); self?.requestClose() }
        model.onSave = { [weak self] in onSave(); self?.requestClose() }
        // Trim keeps the card around — if the trim is cancelled the original is
        // still reachable; a successful trim adds a fresh card for the result.
        model.onEdit = { onTrim() }
        // No cloud upload for recordings/GIFs (too large to host).
        model.onClose = { [weak self] in self?.requestClose() }
        view.onClose = { [weak self] in self?.requestClose() }
    }

    private func requestClose() {
        onRequestClose?(self)
    }

    func show(at origin: NSPoint) {
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func move(to origin: NSPoint, animated: Bool) {
        guard animated else { panel.setFrameOrigin(origin); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().setFrameOrigin(origin)
        }
    }

    func close(animated: Bool, completion: @escaping () -> Void) {
        guard animated else { panel.orderOut(nil); completion(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            let origin = panel.frame.origin
            panel.animator().setFrameOrigin(NSPoint(x: origin.x - 40, y: origin.y))
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
            completion()
        })
    }
}
