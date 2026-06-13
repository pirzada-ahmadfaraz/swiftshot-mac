import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Aspect-ratio constraint used by the crop tool.
enum AspectMode: Equatable {
    case freeform
    case original
    case ratio(Int, Int, String)
    case custom

    var label: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original Ratio"
        case .ratio(_, _, let label): return label
        case .custom: return "Custom Ratio"
        }
    }

    static let presets: [AspectMode] = [
        .ratio(1, 1, "1:1 (Square)"),
        .ratio(5, 4, "5:4"),
        .ratio(7, 5, "7:5"),
        .ratio(4, 3, "4:3"),
        .ratio(3, 2, "3:2"),
        .ratio(16, 9, "16:9")
    ]
}

enum EditorTool: String, CaseIterable, Identifiable {
    case select, rect, rectFilled, ellipse, line, arrow, text, blur, highlight, marker
    case crop, addImage, background

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .select:     return "cursorarrow"
        case .rect:       return "square"
        case .rectFilled: return "square.fill"
        case .ellipse:    return "circle"
        case .line:       return "line.diagonal"
        case .arrow:      return "arrow.up.right"
        case .text:       return "character"
        case .blur:       return "drop.fill"
        case .highlight:  return "rectangle.dashed"
        case .marker:     return "highlighter"
        case .crop:       return "crop"
        case .addImage:   return "photo.badge.plus"
        case .background: return "photo.artframe"
        }
    }
    var label: String {
        switch self {
        case .select:     return "Select"
        case .rect:       return "Rectangle"
        case .rectFilled: return "Filled rectangle"
        case .ellipse:    return "Ellipse"
        case .line:       return "Line"
        case .arrow:      return "Arrow"
        case .text:       return "Text"
        case .blur:       return "Blur"
        case .highlight:  return "Spotlight"
        case .marker:     return "Highlighter"
        case .crop:       return "Crop"
        case .addImage:   return "Add image"
        case .background: return "Change background"
        }
    }

    static let drawingTools: [EditorTool] = [.select, .rect, .rectFilled, .ellipse, .line, .arrow, .text, .blur, .highlight, .marker]
    /// Tools whose own focused toolbar replaces the main one.
    var hasFocusedToolbar: Bool { self == .crop || self == .blur || self == .highlight || self == .background }
    var drawsRegion: Bool {
        switch self {
        case .rect, .rectFilled, .ellipse, .line, .arrow, .blur, .highlight: return true
        default: return false
        }
    }

    /// Color picker visibility in the toolbar.
    var usesColorPicker: Bool {
        switch self {
        case .rect, .rectFilled, .ellipse, .line, .arrow, .text, .marker: return true
        default: return false
        }
    }

    /// Line-thickness control — not available for the freehand highlighter.
    var usesThickness: Bool {
        switch self {
        case .rect, .rectFilled, .ellipse, .line, .arrow, .text: return true
        default: return false
        }
    }

    var usesColorAndThickness: Bool { usesColorPicker }

    /// Freehand highlighter — draws a marker stroke, not a rectangular region.
    var isMarkerTool: Bool { self == .marker }

    /// Whether the user can select and resize existing annotations with handles.
    var showsSelectionHandles: Bool {
        switch self {
        case .crop, .background, .text, .addImage: return false
        default: return true
        }
    }

    /// Shape-drawing tools that support click-to-select after creation.
    var isShapeTool: Bool {
        switch self {
        case .rect, .rectFilled, .ellipse, .line, .arrow, .marker: return true
        default: return false
        }
    }
}

struct Annotation: Identifiable {
    let id = UUID()
    var kind: Kind
    var color: Color
    var lineWidth: CGFloat
    var canvasSize: CGSize

    enum Kind {
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case rectFilled(CGRect)
        case ellipse(CGRect)
        case blur(CGRect, radius: CGFloat)
        case highlight(CGRect)
        case markerStroke(points: [CGPoint])

        var boundingRect: CGRect {
            switch self {
            case .rect(let r), .rectFilled(let r), .ellipse(let r), .blur(let r, _), .highlight(let r):
                return r
            case .markerStroke(let pts):
                guard !pts.isEmpty else { return .zero }
                var r = CGRect.null
                for p in pts { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
                return r
            case .arrow(let f, let t), .line(let f, let t):
                return CGRect(x: min(f.x, t.x), y: min(f.y, t.y),
                              width: abs(t.x - f.x), height: abs(t.y - f.y))
            }
        }

        var isMarker: Bool {
            if case .markerStroke = self { return true }
            return false
        }
    }
}

struct ImageItem: Identifiable {
    let id = UUID()
    let cgImage: CGImage
    let displayImage: NSImage   // downsampled for smooth dragging
    var centerNorm: CGPoint
    var widthNorm: CGFloat
    var aspect: CGFloat
}

struct TextItem: Identifiable {
    let id = UUID()
    var text: String
    var centerNorm: CGPoint
    var fontFrac: CGFloat
    var color: Color
}

@MainActor
final class EditorState: ObservableObject {
    @Published var tool: EditorTool = .arrow
    @Published var annotations: [Annotation] = []
    @Published var imageItems: [ImageItem] = []
    @Published var textItems: [TextItem] = []
    @Published var selectedID: UUID?
    @Published var editingTextID: UUID?
    @Published var selectedAnnotationID: UUID?

    @Published var color: Color = .red
    @Published var lineWidth: CGFloat = 3.0
    @Published var blurRadius: CGFloat = 10
    @Published var highlightDim: CGFloat = 0.6   // darkness of the non-highlighted area

    // Set whenever addBlur is called; lets the blur-radius slider retroactively update it.
    var lastBlurAnnotationID: UUID?
    // Live preview of the background composite used in the canvas while editing other tools.
    @Published var bgPreview: NSImage?

    // Background tool.
    enum BgKind: Equatable { case none, gradient, plain, wallpaper, blurred }
    @Published var bgKind: BgKind = .none
    @Published var bgGradientIndex: Int = 0
    @Published var bgBlurredVariant: Int = 0   // 0 = plain, 1 = dark tint, 2 = light tint
    @Published var bgPlain: Color = .white
    @Published var bgWallpaper: CGImage?
    @Published var bgPadding: CGFloat = 0.08    // 0…0.25 fraction of max dim
    @Published var bgCorners: CGFloat = 0.4     // 0…1
    @Published var bgShadow: CGFloat = 0.35     // 0…1
    @Published var bgInset: CGFloat = 0         // 0…0.2 extra shrink of the image
    @Published var bgAutoBalance: Bool = false
    @Published var bgAlignment: Int = 4         // 0…8, 4 = center
    @Published var bgRatioIndex: Int = 0        // index into bgRatios, 0 = Auto

    static let bgRatios: [(String, CGFloat?)] = [
        ("Auto", nil), ("16:9", 16.0/9), ("3:2", 3.0/2), ("4:3", 4.0/3),
        ("1:1", 1), ("3:4", 3.0/4), ("9:16", 9.0/16)
    ]

    @Published private(set) var workingImage: CGImage {
        didSet {
            displayImage = Self.makeImage(workingImage)
            invalidateFlatCache()
        }
    }
    @Published private(set) var displayImage: NSImage

    @Published var aspectMode: AspectMode = .freeform
    @Published var customW: String = ""
    @Published var customH: String = ""

    private struct BgSnapshot {
        var kind: BgKind
        var gradientIndex: Int
        var blurredVariant: Int
        var plain: Color
        var wallpaper: CGImage?
        var padding: CGFloat
        var corners: CGFloat
        var shadow: CGFloat
        var inset: CGFloat
        var autoBalance: Bool
    }

    private struct Snapshot {
        var image: CGImage
        var annotations: [Annotation]
        var imageItems: [ImageItem]
        var textItems: [TextItem]
        var bg: BgSnapshot
    }
    private var undoStack: [Snapshot] = []
    private let ciContext = CIContext()
    private var bgFlatCache: CGImage?
    private var bgPreviewTask: Task<Void, Never>?

    init(cgImage: CGImage) {
        self.workingImage = cgImage
        self.displayImage = Self.makeImage(cgImage)
    }

    private static func makeImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    var pixelSize: CGSize { CGSize(width: workingImage.width, height: workingImage.height) }
    var hasHighlights: Bool { annotations.contains { if case .highlight = $0.kind { return true } else { return false } } }

    var cropRatio: CGFloat? {
        switch aspectMode {
        case .freeform: return nil
        case .original: return pixelSize.height > 0 ? pixelSize.width / pixelSize.height : nil
        case .ratio(let w, let h, _): return h > 0 ? CGFloat(w) / CGFloat(h) : nil
        case .custom:
            guard let w = Double(customW), let h = Double(customH), w > 0, h > 0 else { return nil }
            return CGFloat(w / h)
        }
    }

    // MARK: - Shape mutations

    func addArrow(from a: CGPoint, to b: CGPoint, canvasSize: CGSize) { add(.arrow(from: a, to: b), canvasSize) }
    func addLine(from a: CGPoint, to b: CGPoint, canvasSize: CGSize) { add(.line(from: a, to: b), canvasSize) }
    func addRect(_ r: CGRect, canvasSize: CGSize) { add(.rect(r), canvasSize) }
    func addRectFilled(_ r: CGRect, canvasSize: CGSize) { add(.rectFilled(r), canvasSize) }
    func addEllipse(_ r: CGRect, canvasSize: CGSize) { add(.ellipse(r), canvasSize) }
    func addBlur(_ r: CGRect, canvasSize: CGSize) {
        add(.blur(r, radius: blurRadius), canvasSize)
        lastBlurAnnotationID = annotations.last?.id
    }
    func addHighlight(_ r: CGRect, canvasSize: CGSize) { add(.highlight(r), canvasSize) }

    func addMarkerStroke(_ points: [CGPoint], width: CGFloat, canvasSize: CGSize) {
        guard points.count >= 2 else { return }
        snapshot()
        let ann = Annotation(kind: .markerStroke(points: points), color: color, lineWidth: width, canvasSize: canvasSize)
        annotations.append(ann)
        selectedAnnotationID = ann.id
        invalidateFlatCache()
    }

    func applyColorToSelectedAnnotation(_ newColor: Color) {
        guard let id = selectedAnnotationID,
              let i = annotations.firstIndex(where: { $0.id == id }),
              annotations[i].kind.isMarker else { return }
        annotations[i].color = newColor
    }

    private func add(_ kind: Annotation.Kind, _ canvasSize: CGSize) {
        snapshot()
        annotations.append(Annotation(kind: kind, color: color, lineWidth: lineWidth, canvasSize: canvasSize))
        selectedAnnotationID = annotations.last?.id
        invalidateFlatCache()
    }

    func invalidateFlatCache() { bgFlatCache = nil }

    /// Call before applying a background change so Undo can revert it.
    func recordBackgroundUndo() { snapshot() }

    func resetBackground() {
        guard bgKind != .none else { return }
        snapshot()
        bgKind = .none
        bgPreview = nil
    }

    func clearCurrentTool() {
        if tool == .background {
            resetBackground()
        } else {
            clear()
        }
    }

    private func captureBg() -> BgSnapshot {
        BgSnapshot(
            kind: bgKind, gradientIndex: bgGradientIndex, blurredVariant: bgBlurredVariant,
            plain: bgPlain, wallpaper: bgWallpaper, padding: bgPadding, corners: bgCorners,
            shadow: bgShadow, inset: bgInset, autoBalance: bgAutoBalance
        )
    }

    private func restoreBg(_ bg: BgSnapshot) {
        bgKind = bg.kind
        bgGradientIndex = bg.gradientIndex
        bgBlurredVariant = bg.blurredVariant
        bgPlain = bg.plain
        bgWallpaper = bg.wallpaper
        bgPadding = bg.padding
        bgCorners = bg.corners
        bgShadow = bg.shadow
        bgInset = bg.inset
        bgAutoBalance = bg.autoBalance
        if bgKind == .none { bgPreview = nil }
    }

    // MARK: - Image & text items

    func addImage(_ cg: CGImage) {
        snapshot()
        let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
        let item = ImageItem(cgImage: cg, displayImage: Self.downsample(cg, maxDim: 900),
                             centerNorm: CGPoint(x: 0.5, y: 0.5), widthNorm: 0.3, aspect: aspect)
        imageItems.append(item)
        selectedID = item.id
    }

    func addText(atNorm p: CGPoint) {
        snapshot()
        let item = TextItem(text: "", centerNorm: p, fontFrac: 0.05, color: color)
        textItems.append(item)
        selectedID = item.id
        editingTextID = item.id
    }

    func updateImage(id: UUID, centerNorm: CGPoint? = nil, widthNorm: CGFloat? = nil) {
        guard let i = imageItems.firstIndex(where: { $0.id == id }) else { return }
        if let centerNorm { imageItems[i].centerNorm = centerNorm }
        if let widthNorm { imageItems[i].widthNorm = max(0.03, min(widthNorm, 1.5)) }
    }
    func updateText(id: UUID, text: String? = nil, centerNorm: CGPoint? = nil) {
        guard let i = textItems.firstIndex(where: { $0.id == id }) else { return }
        if let text { textItems[i].text = text }
        if let centerNorm { textItems[i].centerNorm = centerNorm }
    }
    func commitTextEditing() {
        if let id = editingTextID, let i = textItems.firstIndex(where: { $0.id == id }),
           textItems[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textItems.remove(at: i)
        }
        editingTextID = nil
    }
    func deleteSelected() {
        guard editingTextID == nil else { return }
        guard selectedAnnotationID != nil || selectedID != nil else { return }
        snapshot()
        if let id = selectedAnnotationID {
            annotations.removeAll { $0.id == id }
            selectedAnnotationID = nil
            if lastBlurAnnotationID == id { lastBlurAnnotationID = nil }
            invalidateFlatCache()
        } else if let id = selectedID {
            imageItems.removeAll { $0.id == id }
            textItems.removeAll { $0.id == id }
            selectedID = nil
            invalidateFlatCache()
        }
    }
    func clear() {
        guard !annotations.isEmpty || !imageItems.isEmpty || !textItems.isEmpty else { return }
        snapshot()
        annotations.removeAll(); imageItems.removeAll(); textItems.removeAll()
        selectedID = nil; editingTextID = nil; selectedAnnotationID = nil; lastBlurAnnotationID = nil
    }
    func undo() {
        guard let s = undoStack.popLast() else { return }
        workingImage = s.image
        annotations = s.annotations
        imageItems = s.imageItems
        textItems = s.textItems
        restoreBg(s.bg)
        selectedID = nil
        editingTextID = nil
        selectedAnnotationID = nil
        lastBlurAnnotationID = nil
        invalidateFlatCache()
        if bgKind != .none { refreshBgPreviewNow() } else { bgPreview = nil }
    }

    // MARK: - Annotation mutation (select tool)

    func moveAnnotation(id: UUID, deltaX: CGFloat, deltaY: CGFloat, canvasSize: CGSize) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        let ann = annotations[i]
        let dx = deltaX * ann.canvasSize.width / max(canvasSize.width, 1)
        let dy = deltaY * ann.canvasSize.height / max(canvasSize.height, 1)
        switch ann.kind {
        case .arrow(let f, let t):
            annotations[i].kind = .arrow(from: f.shifted(dx, dy), to: t.shifted(dx, dy))
        case .line(let f, let t):
            annotations[i].kind = .line(from: f.shifted(dx, dy), to: t.shifted(dx, dy))
        case .rect(let r):         annotations[i].kind = .rect(r.offsetBy(dx: dx, dy: dy))
        case .rectFilled(let r):   annotations[i].kind = .rectFilled(r.offsetBy(dx: dx, dy: dy))
        case .ellipse(let r):      annotations[i].kind = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case .blur(let r, let rad): annotations[i].kind = .blur(r.offsetBy(dx: dx, dy: dy), radius: rad)
        case .highlight(let r):    annotations[i].kind = .highlight(r.offsetBy(dx: dx, dy: dy))
        case .markerStroke(let pts):
            annotations[i].kind = .markerStroke(points: pts.map { $0.shifted(dx, dy) })
        }
    }

    func resizeAnnotationRect(id: UUID, newRect: CGRect, canvasSize: CGSize) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        let ann = annotations[i]
        let sx = ann.canvasSize.width / max(canvasSize.width, 1)
        let sy = ann.canvasSize.height / max(canvasSize.height, 1)
        let r = CGRect(x: newRect.minX * sx, y: newRect.minY * sy,
                       width: max(newRect.width * sx, 4), height: max(newRect.height * sy, 4))
        switch ann.kind {
        case .rect:              annotations[i].kind = .rect(r)
        case .rectFilled:        annotations[i].kind = .rectFilled(r)
        case .ellipse:           annotations[i].kind = .ellipse(r)
        case .blur(_, let rad):  annotations[i].kind = .blur(r, radius: rad)
        case .highlight:         annotations[i].kind = .highlight(r)
        default: break
        }
    }

    func updateAnnotationEndpoints(id: UUID, newFrom: CGPoint? = nil, newTo: CGPoint? = nil, canvasSize: CGSize) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        let ann = annotations[i]
        let sx = ann.canvasSize.width / max(canvasSize.width, 1)
        let sy = ann.canvasSize.height / max(canvasSize.height, 1)
        func toAnn(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        switch ann.kind {
        case .arrow(let f, let t):
            annotations[i].kind = .arrow(from: newFrom.map(toAnn) ?? f, to: newTo.map(toAnn) ?? t)
        case .line(let f, let t):
            annotations[i].kind = .line(from: newFrom.map(toAnn) ?? f, to: newTo.map(toAnn) ?? t)
        default: break
        }
    }

    func setBlurRadius(id: UUID, radius: CGFloat) {
        guard let i = annotations.firstIndex(where: { $0.id == id }),
              case .blur(let r, _) = annotations[i].kind else { return }
        annotations[i].kind = .blur(r, radius: radius)
    }

    // MARK: - Background preview

    func updateBgPreview() {
        bgPreviewTask?.cancel()
        bgPreviewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard !Task.isCancelled else { return }
            refreshBgPreviewNow()
        }
    }

    func refreshBgPreviewNow() {
        guard bgKind != .none else { bgPreview = nil; return }
        let img = backgroundComposite(forPreview: true)
        bgPreview = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }

    /// Centers the image and picks padding so margins look even.
    func applyAutoBalance() {
        guard bgAutoBalance else { return }

        let imgW = CGFloat(workingImage.width)
        let imgH = CGFloat(workingImage.height)
        guard imgW > 0, imgH > 0 else { return }
        let imgAspect = imgW / imgH
        bgPadding = Self.balancedPadding(imgW: imgW, imgH: imgH, targetRatio: imgAspect)
    }

    /// Padding fraction (0…0.25) that yields visually balanced margins.
    private static func balancedPadding(imgW: CGFloat, imgH: CGFloat, targetRatio: CGFloat) -> CGFloat {
        let maxDim = max(imgW, imgH)
        let imgAspect = imgW / imgH
        var bestPad: CGFloat = 0.08
        var bestScore = CGFloat.greatestFiniteMagnitude

        var p: CGFloat = 0.04
        while p <= 0.24 {
            let pad = maxDim * p
            var cw = imgW + pad * 2
            var ch = imgH + pad * 2
            if targetRatio > 0 {
                if cw / ch < targetRatio { cw = ch * targetRatio }
                else { ch = cw / targetRatio }
            }
            let slotW = cw - pad * 2
            let slotH = ch - pad * 2
            let scale = min(slotW / imgW, slotH / imgH)
            let drawW = imgW * scale
            let drawH = imgH * scale
            let marginX = (slotW - drawW) / 2 + pad
            let marginY = (slotH - drawH) / 2 + pad
            let score = abs(marginX - marginY) + abs(imgAspect - targetRatio) * 0.02
            if score < bestScore { bestScore = score; bestPad = p }
            p += 0.01
        }
        return bestPad
    }

    private func cachedFlat() -> CGImage {
        if let bgFlatCache { return bgFlatCache }
        let flat = flattened()
        bgFlatCache = flat
        return flat
    }

    func rotate90() {
        let source = CIImage(cgImage: flattened())
        let rotated = source.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
        let upright = rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.origin.x,
            y: -rotated.extent.origin.y
        ))
        guard let r = ciContext.createCGImage(upright, from: upright.extent) else { return }
        snapshot(); setBaked(r)
    }

    func flipHorizontal() {
        let source = CIImage(cgImage: flattened())
        let flipped = source.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
            .translatedBy(x: -source.extent.width, y: 0))
        guard let r = ciContext.createCGImage(flipped, from: flipped.extent) else { return }
        snapshot(); setBaked(r)
    }

    func applyCropNormalized(_ norm: CGRect) {
        let flat = flattened()
        let W = CGFloat(flat.width), H = CGFloat(flat.height)
        let pixelRect = CGRect(x: norm.minX * W, y: norm.minY * H, width: norm.width * W, height: norm.height * H)
            .integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard pixelRect.width >= 1, pixelRect.height >= 1, let cropped = flat.cropping(to: pixelRect) else { return }
        snapshot(); setBaked(cropped)
    }

    /// Preset gradient hex pairs (top-left → bottom-right). Stored as ints so the literal
    /// type-checks instantly; converted to Colors on demand.
    static let gradientHexes: [(UInt32, UInt32)] = [
        (0xFF6B6B, 0xFFD93D), (0x6A82FB, 0xFC5C7D), (0x1A2980, 0x26D0CE), (0x43C6AC, 0xF8FFAE),
        (0xFF512F, 0xDD2476), (0x8E2DE2, 0x4A00E0), (0xF5F7FA, 0xC3CFE2), (0xE0EAFC, 0xCFDEF3),
        (0x2C3E50, 0x4CA1AF), (0x3A7BD5, 0x00D2FF), (0xA1C4FD, 0xC2E9FB), (0xD4FC79, 0x96E6A1),
        (0xFF9A9E, 0xFAD0C4), (0x667EEA, 0x764BA2), (0xF093FB, 0xF5576C), (0x4FACFE, 0x00F2FE),
        (0xFA709A, 0xFEE140), (0x30CFD0, 0x330867), (0xFF5F6D, 0xFFC371), (0x09203F, 0x537895)
    ]
    static var gradientCount: Int { gradientHexes.count }
    static func gradientColors(_ index: Int) -> [Color] {
        let pair = gradientHexes[min(max(index, 0), gradientHexes.count - 1)]
        return [Color(hex: pair.0), Color(hex: pair.1)]
    }

    /// Composites the current image onto the chosen background, honoring padding, inset,
    /// ratio, alignment, rounded corners, and a drop shadow. `forPreview` downsamples for
    /// smooth slider dragging.
    func backgroundComposite(forPreview: Bool) -> CGImage {
        let full = forPreview ? cachedFlat() : flattened()
        if bgKind == .none { return full }
        let base = forPreview ? Self.downsampleCG(full, maxDim: 720) : full
        let imgW = CGFloat(base.width), imgH = CGFloat(base.height)
        let maxDim = max(imgW, imgH)
        let pad = maxDim * max(0, bgPadding)

        let canvasW = imgW + pad * 2
        let canvasH = imgH + pad * 2
        let nw = max(Int(canvasW.rounded()), 1), nh = max(Int(canvasH.rounded()), 1)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(nw), height: CGFloat(nh))

        fillBackground(in: ctx, rect: canvas, fullImage: full)

        // Slot = canvas inset by padding; fit the image inside, shrunk by inset, aligned.
        let slot = canvas.insetBy(dx: pad, dy: pad)
        let scale = min(slot.width / imgW, slot.height / imgH) * (1 - min(bgInset, 0.95))
        let drawW = imgW * scale, drawH = imgH * scale
        // Always center the image in the frame.
        let x = slot.minX + (slot.width - drawW) / 2
        let y = slot.minY + (slot.height - drawH) / 2
        let r = CGRect(x: x, y: y, width: drawW, height: drawH)

        let radius = min(drawW, drawH) * 0.12 * bgCorners
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if bgShadow > 0.01 {
            ctx.saveGState()
            let blur = 6 + bgShadow * maxDim * 0.05
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.3), blur: blur, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState(); ctx.addPath(path); ctx.clip(); ctx.draw(base, in: r); ctx.restoreGState()
        return ctx.makeImage() ?? base
    }

    private func fillBackground(in ctx: CGContext, rect canvas: CGRect, fullImage full: CGImage) {
        switch bgKind {
        case .plain:
            ctx.setFillColor(NSColor(bgPlain).cgColor); ctx.fill(canvas)
        case .gradient:
            drawGradient(in: ctx, rect: canvas, colors: Self.gradientColors(bgGradientIndex))
        case .wallpaper:
            if let wp = bgWallpaper { drawFill(wp, in: ctx, rect: canvas) }
            else { ctx.setFillColor(NSColor.darkGray.cgColor); ctx.fill(canvas) }
        case .blurred:
            let src = CIImage(cgImage: full)
            let ci = src.clampedToExtent().applyingGaussianBlur(sigma: Double(max(full.width, full.height)) * 0.04).cropped(to: src.extent)
            if let blurredCG = ciContext.createCGImage(ci, from: src.extent) { drawFill(blurredCG, in: ctx, rect: canvas) }
            // Tint variants: dark / light.
            if bgBlurredVariant == 1 { ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor); ctx.fill(canvas) }
            else if bgBlurredVariant == 2 { ctx.setFillColor(NSColor.white.withAlphaComponent(0.4).cgColor); ctx.fill(canvas) }
        case .none:
            break
        }
    }

    /// The final exported image — annotations flattened, with the background frame applied.
    func finalImage() -> CGImage {
        bgKind == .none ? flattened() : backgroundComposite(forPreview: false)
    }

    private func drawGradient(in ctx: CGContext, rect: CGRect, colors: [Color]) {
        let cgColors = colors.map { NSColor($0).cgColor } as CFArray
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil) else { return }
        ctx.saveGState(); ctx.addRect(rect); ctx.clip()
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    private func drawFill(_ image: CGImage, in ctx: CGContext, rect: CGRect) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = max(rect.width / iw, rect.height / ih)
        let dw = iw * scale, dh = ih * scale
        let dr = CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh)
        ctx.saveGState(); ctx.addRect(rect); ctx.clip(); ctx.draw(image, in: dr); ctx.restoreGState()
    }

    private static func downsampleCG(_ image: CGImage, maxDim: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, maxDim / max(w, h))
        guard scale < 1 else { return image }
        let tw = max(Int(w * scale), 1), th = max(Int(h * scale), 1)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? image
    }

    private func setBaked(_ image: CGImage) {
        workingImage = image
        annotations.removeAll(); imageItems.removeAll(); textItems.removeAll()
        selectedID = nil; editingTextID = nil; selectedAnnotationID = nil; lastBlurAnnotationID = nil
        invalidateFlatCache()
        updateBgPreview()
    }

    private func snapshot() {
        undoStack.append(Snapshot(
            image: workingImage,
            annotations: annotations,
            imageItems: imageItems,
            textItems: textItems,
            bg: captureBg()
        ))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    // MARK: - Flatten

    func flattened() -> CGImage {
        let width = workingImage.width, height = workingImage.height
        let colorSpace = workingImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return workingImage }
        let W = CGFloat(width), H = CGFloat(height)

        ctx.draw(workingImage, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // top-left origin

        // Blur regions hide the underlying content first.
        for ann in annotations {
            if case .blur(let r, let radius) = ann.kind {
                drawBlurPatch(r, radius: radius, ann.canvasSize, in: ctx, imageW: W, imageH: H)
            }
        }

        for ann in annotations { drawShape(ann, in: ctx, imageW: W, imageH: H) }

        for item in imageItems {
            let w = item.widthNorm * W, h = (item.widthNorm * W) / item.aspect
            let r = CGRect(x: item.centerNorm.x * W - w / 2, y: item.centerNorm.y * H - h / 2, width: w, height: h)
            drawImageUpright(item.cgImage, in: r, ctx: ctx)
        }
        for item in textItems where !item.text.isEmpty {
            guard let ti = Self.renderText(item.text, fontSizePx: item.fontFrac * H, color: item.color) else { continue }
            let w = CGFloat(ti.width), h = CGFloat(ti.height)
            let r = CGRect(x: item.centerNorm.x * W - w / 2, y: item.centerNorm.y * H - h / 2, width: w, height: h)
            drawImageUpright(ti, in: r, ctx: ctx)
        }

        // Spotlight: dim everything outside the highlight regions.
        if hasHighlights {
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: W, height: H))
            for ann in annotations {
                if case .highlight(let r) = ann.kind {
                    path.addRect(scaledRect(r, ann.canvasSize, W, H))
                }
            }
            ctx.setFillColor(NSColor.black.withAlphaComponent(highlightDim).cgColor)
            ctx.addPath(path); ctx.fillPath(using: .evenOdd)
        }

        return ctx.makeImage() ?? workingImage
    }

    private func scaledRect(_ r: CGRect, _ canvas: CGSize, _ W: CGFloat, _ H: CGFloat) -> CGRect {
        let sx = W / max(canvas.width, 1), sy = H / max(canvas.height, 1)
        return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    private func drawImageUpright(_ img: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY + r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    private func drawBlurPatch(_ r: CGRect, radius: CGFloat, _ canvas: CGSize, in ctx: CGContext, imageW W: CGFloat, imageH H: CGFloat) {
        let pr = scaledRect(r, canvas, W, H)
        let sigma = max(2, radius * (W / max(canvas.width, 1)))
        let ci = CIImage(cgImage: workingImage)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: ci.extent)
        guard let blurredCG = ciContext.createCGImage(blurred, from: ci.extent) else { return }
        ctx.saveGState()
        ctx.addRect(pr); ctx.clip()
        ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(blurredCG, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.restoreGState()
    }

    private func drawShape(_ ann: Annotation, in ctx: CGContext, imageW W: CGFloat, imageH H: CGFloat) {
        let sx = W / max(ann.canvasSize.width, 1), sy = H / max(ann.canvasSize.height, 1)
        let s = (sx + sy) / 2
        ctx.setStrokeColor(NSColor(ann.color).cgColor)
        ctx.setFillColor(NSColor(ann.color).cgColor)
        ctx.setLineWidth(ann.lineWidth * s); ctx.setLineCap(.round)
        func sr(_ r: CGRect) -> CGRect { CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy) }
        switch ann.kind {
        case .arrow(let f, let t):
            drawArrow(in: ctx, from: CGPoint(x: f.x * sx, y: f.y * sy), to: CGPoint(x: t.x * sx, y: t.y * sy), lineWidth: ann.lineWidth * s)
        case .line(let f, let t):
            ctx.move(to: CGPoint(x: f.x * sx, y: f.y * sy)); ctx.addLine(to: CGPoint(x: t.x * sx, y: t.y * sy)); ctx.strokePath()
        case .rect(let r): ctx.stroke(sr(r))
        case .rectFilled(let r): ctx.fill(sr(r))
        case .ellipse(let r): ctx.strokeEllipse(in: sr(r))
        case .markerStroke(let pts):
            guard pts.count >= 2 else { break }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: pts[0].x * sx, y: pts[0].y * sy))
            for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x * sx, y: p.y * sy)) }
            ctx.setLineWidth(ann.lineWidth * s)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor(ann.color).withAlphaComponent(MarkerStroke.fillOpacity).cgColor)
            ctx.addPath(path)
            ctx.strokePath()
        case .blur, .highlight: break   // handled separately
        }
    }

    private func drawArrow(in ctx: CGContext, from: CGPoint, to: CGPoint, lineWidth: CGFloat) {
        ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
        let angle = atan2(to.y - from.y, to.x - from.x)
        let hl = max(10, lineWidth * 3); let ha: CGFloat = .pi / 6
        let p1 = CGPoint(x: to.x - hl * cos(angle - ha), y: to.y - hl * sin(angle - ha))
        let p2 = CGPoint(x: to.x - hl * cos(angle + ha), y: to.y - hl * sin(angle + ha))
        ctx.move(to: to); ctx.addLine(to: p1); ctx.strokePath()
        ctx.move(to: to); ctx.addLine(to: p2); ctx.strokePath()
    }

    private static func renderText(_ text: String, fontSizePx: CGFloat, color: Color) -> CGImage? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(fontSizePx, 4), weight: .semibold),
            .foregroundColor: NSColor(color)
        ]
        let astr = NSAttributedString(string: text, attributes: attrs)
        let size = astr.size()
        let w = Int(ceil(size.width)) + 4, h = Int(ceil(size.height)) + 4
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        astr.draw(at: NSPoint(x: 2, y: 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func downsample(_ image: CGImage, maxDim: CGFloat) -> NSImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, maxDim / max(w, h))
        let tw = max(Int(w * scale), 1), th = max(Int(h * scale), 1)
        guard scale < 1,
              let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        let out = ctx.makeImage() ?? image
        return NSImage(cgImage: out, size: NSSize(width: tw, height: th))
    }
}

extension CGPoint {
    func shifted(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

extension Color {
    /// Build a Color from a 24-bit RGB hex value, e.g. `Color(hex: 0xFF6B6B)`.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
