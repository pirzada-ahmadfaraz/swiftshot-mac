import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var state: EditorState
    let onSaveAs: () -> Void
    let onDone: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var cropNorm = CGRect.zero
    @State private var showColorPopover = false
    @State private var selectDragLast: CGPoint?
    @State private var markerPoints: [CGPoint] = []
    @State private var markerWidth: CGFloat = 14

    private static let thicknessOptions: [(String, CGFloat)] = [("Thin", 2), ("Medium", 4), ("Thick", 7), ("Heavy", 11)]

    var body: some View {
        Group {
            if state.tool == .background {
                backgroundLayout
            } else {
                standardLayout
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .focusable()
        .onDeleteCommand {
            if state.tool == .background { state.resetBackground() }
            else if state.editingTextID == nil { state.deleteSelected() }
        }
        .onChange(of: state.tool) {
            if state.tool == .crop { resetCrop() }
            if state.tool == .highlight || state.tool == .blur { state.selectedAnnotationID = nil }
            markerPoints = []
            if state.tool == .marker { state.color = MarkerStroke.defaultColor }
            if state.tool == .background {
                if state.bgAutoBalance { state.applyAutoBalance() }
                state.refreshBgPreviewNow()
            } else {
                state.updateBgPreview()
            }
        }
        .onChange(of: state.aspectMode) { fitCropToRatio() }
        .onChange(of: state.customW) { fitCropToRatio() }
        .onChange(of: state.customH) { fitCropToRatio() }
        .onChange(of: state.color) { state.applyColorToSelectedAnnotation(state.color) }
    }

    private var standardLayout: some View {
        VStack(spacing: 0) {
            switch state.tool {
            case .crop:       cropToolbar
            case .blur:       blurToolbar
            case .highlight:  highlightToolbar
            default:          toolbar
            }
            canvas
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var backgroundLayout: some View {
        VStack(spacing: 0) {
            toolbar   // the editing toolbar stays; background button is highlighted
            HStack(spacing: 0) {
                BackgroundPanel(state: state, onAddWallpaper: pickWallpaper)
                    .frame(width: 218)
                Divider()
                backgroundPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var backgroundPreview: some View {
        Group {
            if let preview = state.bgPreview {
                Image(nsImage: preview)
                    .resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: state.displayImage)
                    .resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .padding(28)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .drawingGroup()
    }

    private func pickWallpaper() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        state.recordBackgroundUndo()
        state.bgWallpaper = cg
        state.bgKind = .wallpaper
    }

    // MARK: - Crop helpers

    private func resetCrop() {
        cropNorm = .zero
    }
    private func fitCropToRatio() {
        guard state.tool == .crop, cropNorm.width > 0.001, cropNorm.height > 0.001,
              let ratio = state.cropRatio, ratio > 0 else { return }
        let W = state.pixelSize.width, H = state.pixelSize.height
        guard W > 0, H > 0 else { return }
        var cw = W, ch = H
        if W / H > ratio { ch = H; cw = H * ratio } else { cw = W; ch = W / ratio }
        let nw = cw / W, nh = ch / H
        cropNorm = CGRect(x: (1 - nw) / 2, y: (1 - nh) / 2, width: nw, height: nh)
    }
    private func applyCrop() {
        guard cropNorm.width > 0.001, cropNorm.height > 0.001 else { return }
        state.applyCropNormalized(cropNorm)
        state.tool = .select
    }

    // MARK: - Toolbar

    private var blueGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.20, green: 0.32, blue: 0.52), Color(red: 0.12, green: 0.18, blue: 0.32)],
                       startPoint: .top, endPoint: .bottom)
    }

    private func barWrap<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 70)
            content()
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(blueGradient)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.3)).frame(height: 0.5) }
    }

    private var toolbar: some View {
        barWrap {
            // Crop + add-image + background group.
            HStack(spacing: 2) {
                ToolButton(systemImage: "crop", isSelected: false) { state.tool = .crop }
                    .help("Crop")
                ToolButton(systemImage: "photo.badge.plus", isSelected: false) { pickImages() }
                    .help("Add image")
                ToolButton(systemImage: "photo.artframe", isSelected: state.tool == .background) { state.tool = .background }
                    .help("Change background")
            }
            .padding(4)
            .background(toolGroupBackground)

            // Drawing tools.
            HStack(spacing: 2) {
                ForEach(EditorTool.drawingTools) { tool in
                    ToolButton(systemImage: tool.systemImage, isSelected: state.tool == tool) { state.tool = tool }
                        .help(tool.label)
                }
            }
            .padding(4)
            .background(toolGroupBackground)

            // Color (and thickness where applicable) for drawing tools.
            if state.tool.usesColorPicker {
                HStack(spacing: 6) {
                    colorControl
                    if state.tool.usesThickness { thicknessControl }
                }
                .padding(4)
                .background(toolGroupBackground)
            }

            HStack(spacing: 2) {
                IconButton(systemName: "arrow.uturn.backward", action: state.undo).help("Undo")
                    .keyboardShortcut("z", modifiers: .command)
                IconButton(systemName: "trash", action: state.clearCurrentTool).help("Clear")
            }
            .padding(4)
            .background(toolGroupBackground)

            Spacer()

            Button("Save as…", action: onSaveAs).buttonStyle(BarTextButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
            Button("Done", action: onDone).buttonStyle(BarPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private var cropToolbar: some View {
        barWrap {
            Button { state.tool = .select } label: {
                Image(systemName: "crop").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor))
            }
            .buttonStyle(.plain).help("Done cropping")

            Menu {
                Button("Custom Ratio") { state.aspectMode = .custom }
                Button("Freeform") { state.aspectMode = .freeform }
                Divider()
                Button("Original Ratio") { state.aspectMode = .original }
                ForEach(Array(AspectMode.presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.label) { state.aspectMode = preset }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(state.aspectMode.label).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(width: 130, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 26)
                .background(toolGroupBackground)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

            HStack(spacing: 6) {
                ratioField($state.customW)
                Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                ratioField($state.customH)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(toolGroupBackground)

            HStack(spacing: 2) {
                IconButton(systemName: "rotate.right", action: state.rotate90).help("Rotate 90°")
                IconButton(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: state.flipHorizontal).help("Flip horizontally")
            }
            .padding(4)
            .background(toolGroupBackground)

            Spacer()

            Text("Image size: \(Int(state.pixelSize.width)) × \(Int(state.pixelSize.height)) px")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            Button("Done", action: applyCrop).buttonStyle(BarPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private func focusedHeader(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor))
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        }
    }

    private var blurToolbar: some View {
        barWrap {
            focusedHeader("drop.fill", "Blur")
            HStack(spacing: 8) {
                Text("Amount").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Slider(value: $state.blurRadius, in: 2...40).frame(width: 140).controlSize(.small)
                    .onChange(of: state.blurRadius) {
                        let id = state.selectedAnnotationID ?? state.lastBlurAnnotationID
                        if let id { state.setBlurRadius(id: id, radius: state.blurRadius) }
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 4).background(toolGroupBackground)
            Text("Drag over the area to blur").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button("Done") { state.tool = .select }.buttonStyle(BarPrimaryButtonStyle())
        }
    }

    private var highlightToolbar: some View {
        barWrap {
            focusedHeader("rectangle.dashed", "Highlight")
            HStack(spacing: 8) {
                Text("Dim").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .fixedSize().lineLimit(1)
                Slider(value: $state.highlightDim, in: 0...0.9).frame(width: 140).controlSize(.small)
            }
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 4).background(toolGroupBackground)
            Text("Drag to spotlight · resize after selecting").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            Spacer()
            IconButton(systemName: "arrow.uturn.backward", action: state.undo).help("Revert")
            Button("Done") { state.tool = .select; state.selectedAnnotationID = nil }.buttonStyle(BarPrimaryButtonStyle())
        }
    }

    private func ratioField(_ binding: Binding<String>) -> some View {
        TextField("", text: binding)
            .textFieldStyle(.plain).multilineTextAlignment(.center)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .frame(width: 42, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.32)))
            .onChange(of: binding.wrappedValue) {
                if !state.customW.isEmpty || !state.customH.isEmpty { state.aspectMode = .custom }
            }
    }

    private var toolGroupBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.black.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    // Round color swatch matching the toolbar theme.
    private var colorControl: some View {
        Button { showColorPopover.toggle() } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .frame(width: 36, height: 28)
                .overlay(
                    Circle()
                        .fill(state.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.75))
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
            ColorPalettePopover(selection: $state.color)
        }
    }

    // Thickness dropdown with a live line preview.
    private var thicknessControl: some View {
        Menu {
            ForEach(Array(Self.thicknessOptions.enumerated()), id: \.offset) { _, opt in
                Button(opt.0) { state.lineWidth = opt.1 }
            }
        } label: {
            HStack(spacing: 5) {
                Capsule().fill(Color.white)
                    .frame(width: 18, height: max(2, min(state.lineWidth, 11)))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 44, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    // MARK: - Canvas

    private var canvas: some View {
        editingCanvas
    }

    private var editingCanvas: some View {
        let baseImage = state.bgPreview ?? state.displayImage
        return ZStack {
            Image(nsImage: baseImage).resizable().interpolation(.high)
            GeometryReader { geo in
                ZStack {
                    Canvas { context, size in
                        for ann in state.annotations { drawAnnotation(ann, in: context, currentSize: size) }
                        if state.tool != .select, state.selectedAnnotationID == nil { drawDraft(in: context, size: size) }
                        // Dashed selection border when an annotation is selected.
                        if state.selectedAnnotationID != nil, state.tool.showsSelectionHandles,
                           let id = state.selectedAnnotationID,
                           let ann = state.annotations.first(where: { $0.id == id }) {
                            drawSelectionBorder(ann, in: context, size: size)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(drawGesture(canvasSize: geo.size), including: state.tool == .crop ? .subviews : .all)
                    .onChange(of: state.selectedAnnotationID) {
                        if let id = state.selectedAnnotationID,
                           let ann = state.annotations.first(where: { $0.id == id }) {
                            if case .blur(_, let radius) = ann.kind {
                                state.blurRadius = radius
                            } else if ann.kind.isMarker {
                                state.color = ann.color
                            }
                        }
                    }

                    // Blur regions (real GPU blur of the underlying image, masked to each rect).
                    ForEach(blurAnnotations) { ann in
                        blurOverlay(ann, geo: geo.size)
                    }

                    // Spotlight dim overlay (dims everything outside highlight regions).
                    if state.hasHighlights || (state.tool == .highlight && dragStart != nil) {
                        highlightOverlay(geo: geo.size)
                    }

                    ForEach(state.imageItems) { item in
                        ImageItemView(item: item, canvasSize: geo.size, state: state)
                    }
                    ForEach(state.textItems) { item in
                        TextItemView(item: item, canvasSize: geo.size, state: state)
                    }

                    if state.selectedAnnotationID != nil, state.tool.showsSelectionHandles,
                       let selID = state.selectedAnnotationID,
                       let selAnn = state.annotations.first(where: { $0.id == selID }) {
                        AnnotationSelectionView(annotation: selAnn, canvasSize: geo.size, state: state)
                    }

                    if state.tool == .crop {
                        CropOverlay(norm: $cropNorm, canvasSize: geo.size, ratio: state.cropRatio)
                    }
                }
            }
        }
        .aspectRatio(state.pixelSize.width / max(state.pixelSize.height, 1), contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private var blurAnnotations: [Annotation] {
        state.annotations.filter { if case .blur = $0.kind { return true } else { return false } }
    }

    private func blurOverlay(_ ann: Annotation, geo: CGSize) -> some View {
        let scaleX = geo.width / max(ann.canvasSize.width, 1)
        let scaleY = geo.height / max(ann.canvasSize.height, 1)
        var rect = CGRect.zero
        var radius: CGFloat = 0
        if case .blur(let r, let rad) = ann.kind {
            rect = CGRect(x: r.minX * scaleX, y: r.minY * scaleY, width: r.width * scaleX, height: r.height * scaleY)
            radius = rad * scaleX
        }
        return Image(nsImage: state.displayImage)
            .resizable()
            .frame(width: geo.width, height: geo.height)
            .blur(radius: radius, opaque: true)
            .mask(Rectangle().frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY))
            .allowsHitTesting(false)
    }

    private func highlightOverlay(geo: CGSize) -> some View {
        Canvas { ctx, size in
            var path = Path(CGRect(origin: .zero, size: size))
            for ann in state.annotations {
                if case .highlight(let r) = ann.kind {
                    path.addRect(scaledRect(r, ann.canvasSize, size))
                }
            }
            if state.tool == .highlight, let s = dragStart, let c = dragCurrent {
                path.addRect(rectBetween(s, c))
            }
            ctx.fill(path, with: .color(.black.opacity(state.highlightDim)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private func scaledRect(_ r: CGRect, _ canvas: CGSize, _ geo: CGSize) -> CGRect {
        let sx = geo.width / max(canvas.width, 1), sy = geo.height / max(canvas.height, 1)
        return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    private func drawGesture(canvasSize: CGSize) -> some Gesture {
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if state.tool == .marker {
                    if dragStart == nil {
                        dragStart = value.startLocation
                        state.commitTextEditing()
                        if let hit = annotationHitTest(point: value.startLocation, canvasSize: canvasSize) {
                            state.selectedAnnotationID = hit
                            selectDragLast = value.startLocation
                        } else {
                            state.selectedAnnotationID = nil
                            markerWidth = MarkerStroke.estimateWidth(
                                at: value.startLocation, canvasSize: canvasSize, image: state.workingImage
                            )
                            markerPoints = [value.startLocation]
                        }
                        return
                    }
                    if let id = state.selectedAnnotationID, let last = selectDragLast {
                        let dx = value.location.x - last.x, dy = value.location.y - last.y
                        if abs(dx) > 0.5 || abs(dy) > 0.5 {
                            state.moveAnnotation(id: id, deltaX: dx, deltaY: dy, canvasSize: canvasSize)
                            selectDragLast = value.location
                        }
                        return
                    }
                    if let last = markerPoints.last {
                        let d = hypot(value.location.x - last.x, value.location.y - last.y)
                        if d >= 2.5 { markerPoints.append(value.location) }
                    }
                    return
                }
                if state.tool == .select || state.tool.isShapeTool {
                    if dragStart == nil {
                        dragStart = value.startLocation
                        state.commitTextEditing()
                        if state.tool == .select, let textID = textHitTest(point: value.startLocation, canvasSize: canvasSize) {
                            state.selectedID = textID
                            state.selectedAnnotationID = nil
                        } else if let hit = annotationHitTest(point: value.startLocation, canvasSize: canvasSize) {
                            state.selectedAnnotationID = hit
                            state.selectedID = nil
                        } else {
                            state.selectedAnnotationID = nil
                            state.selectedID = nil
                        }
                        selectDragLast = value.startLocation
                    }
                    guard state.selectedAnnotationID != nil,
                          state.selectedID == nil,
                          let id = state.selectedAnnotationID,
                          let last = selectDragLast else {
                        if state.tool.isShapeTool, state.selectedAnnotationID == nil {
                            dragCurrent = value.location
                        }
                        selectDragLast = value.location
                        return
                    }
                    let movedEnough = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
                    guard movedEnough else { return }
                    let dx = value.location.x - last.x, dy = value.location.y - last.y
                    state.moveAnnotation(id: id, deltaX: dx, deltaY: dy, canvasSize: canvasSize)
                    selectDragLast = value.location
                    return
                }
                if state.tool == .highlight || state.tool == .blur {
                    if dragStart == nil {
                        dragStart = value.startLocation
                        if let hit = regionAnnotationHitTest(point: value.startLocation, canvasSize: canvasSize, kind: state.tool) {
                            state.selectedAnnotationID = hit
                            selectDragLast = value.startLocation
                            return
                        }
                        state.selectedAnnotationID = nil
                    }
                    if let id = state.selectedAnnotationID, let last = selectDragLast {
                        let dx = value.location.x - last.x, dy = value.location.y - last.y
                        if abs(dx) > 0.5 || abs(dy) > 0.5 {
                            state.moveAnnotation(id: id, deltaX: dx, deltaY: dy, canvasSize: canvasSize)
                            selectDragLast = value.location
                        }
                        return
                    }
                    guard state.selectedAnnotationID == nil else { return }
                    dragCurrent = value.location
                    return
                }
                if state.tool == .text {
                    if dragStart == nil { dragStart = value.startLocation }
                    return
                }
                guard state.tool.drawsRegion else { return }
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                if state.tool == .marker {
                    defer { dragStart = nil; markerPoints = []; selectDragLast = nil }
                    if state.selectedAnnotationID != nil { return }
                    let pts = MarkerStroke.simplified(markerPoints)
                    guard pts.count >= 2 else { return }
                    state.addMarkerStroke(pts, width: markerWidth, canvasSize: canvasSize)
                    return
                }
                if state.tool == .select || state.tool.isShapeTool {
                    let isTap = abs(value.translation.width) < 5 && abs(value.translation.height) < 5
                    if isTap && dragStart == nil {
                        state.commitTextEditing()
                        if state.tool == .select, let textID = textHitTest(point: value.startLocation, canvasSize: canvasSize) {
                            state.selectedID = textID
                            state.selectedAnnotationID = nil
                        } else if let hit = annotationHitTest(point: value.startLocation, canvasSize: canvasSize) {
                            state.selectedAnnotationID = hit
                            state.selectedID = nil
                        } else {
                            state.selectedAnnotationID = nil
                            state.selectedID = nil
                        }
                    }
                    if state.tool.isShapeTool, state.selectedAnnotationID == nil,
                       let s = dragStart, abs(value.translation.width) > 4 || abs(value.translation.height) > 4 {
                        let end = value.location
                        switch state.tool {
                        case .arrow: state.addArrow(from: s, to: end, canvasSize: canvasSize)
                        case .line:  state.addLine(from: s, to: end, canvasSize: canvasSize)
                        case .rect:  state.addRect(rectBetween(s, end), canvasSize: canvasSize)
                        case .rectFilled: state.addRectFilled(rectBetween(s, end), canvasSize: canvasSize)
                        case .ellipse: state.addEllipse(rectBetween(s, end), canvasSize: canvasSize)
                        default: break
                        }
                    }
                    dragStart = nil; dragCurrent = nil; selectDragLast = nil
                    return
                }
                if state.tool == .select {
                    dragStart = nil; dragCurrent = nil; selectDragLast = nil; return
                }
                if state.tool == .highlight || state.tool == .blur {
                    if state.selectedAnnotationID != nil {
                        dragStart = nil; dragCurrent = nil; selectDragLast = nil; return
                    }
                    defer { dragStart = nil; dragCurrent = nil }
                    let start = dragStart ?? value.startLocation
                    let end = value.location
                    let r = rectBetween(start, end)
                    guard r.width > 4, r.height > 4 else { return }
                    switch state.tool {
                    case .blur:
                        state.addBlur(r, canvasSize: canvasSize)
                        state.selectedAnnotationID = state.annotations.last?.id
                    case .highlight:
                        state.addHighlight(r, canvasSize: canvasSize)
                        state.selectedAnnotationID = state.annotations.last?.id
                    default: break
                    }
                    return
                }
                if state.tool == .text {
                    defer { dragStart = nil }
                    let start = dragStart ?? value.startLocation
                    let n = CGPoint(x: start.x / canvasSize.width, y: start.y / canvasSize.height)
                    state.addText(atNorm: n)
                    return
                }
                defer { dragStart = nil; dragCurrent = nil }
                state.selectedAnnotationID = nil
            }
    }

    private func textHitTest(point: CGPoint, canvasSize: CGSize) -> UUID? {
        for item in state.textItems.reversed() {
            let fontSize = item.fontFrac * canvasSize.height
            let center = CGPoint(x: item.centerNorm.x * canvasSize.width, y: item.centerNorm.y * canvasSize.height)
            let w = max(fontSize * CGFloat(max(item.text.count, 1)) * 0.55, 24)
            let h = fontSize * 1.4
            let r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            if r.insetBy(dx: -6, dy: -6).contains(point) { return item.id }
        }
        return nil
    }

    private func regionAnnotationHitTest(point: CGPoint, canvasSize: CGSize, kind: EditorTool) -> UUID? {
        for ann in state.annotations.reversed() {
            let matches: Bool = switch (kind, ann.kind) {
            case (.highlight, .highlight): true
            case (.blur, .blur): true
            default: false
            }
            guard matches else { continue }
            let sx = canvasSize.width / max(ann.canvasSize.width, 1)
            let sy = canvasSize.height / max(ann.canvasSize.height, 1)
            if ann.kind.boundingRect.scaled(sx, sy).insetBy(dx: -8, dy: -8).contains(point) {
                return ann.id
            }
        }
        return nil
    }

    // MARK: - Annotation hit-test

    private func annotationHitTest(point: CGPoint, canvasSize: CGSize) -> UUID? {
        for ann in state.annotations.reversed() {
            let sx = canvasSize.width / max(ann.canvasSize.width, 1)
            let sy = canvasSize.height / max(ann.canvasSize.height, 1)
            if annotationContains(ann, point: point, sx: sx, sy: sy) { return ann.id }
        }
        return nil
    }

    private func annotationContains(_ ann: Annotation, point p: CGPoint, sx: CGFloat, sy: CGFloat) -> Bool {
        let tol: CGFloat = 8
        switch ann.kind {
        case .arrow(let f, let t), .line(let f, let t):
            let a = CGPoint(x: f.x * sx, y: f.y * sy), b = CGPoint(x: t.x * sx, y: t.y * sy)
            return pointToSegmentDistance(p, a, b) < tol
        case .rect(let r):
            let sr = r.scaled(sx, sy)
            return sr.insetBy(dx: -tol, dy: -tol).contains(p) && !sr.insetBy(dx: tol, dy: tol).contains(p)
        case .rectFilled(let r):
            return r.scaled(sx, sy).insetBy(dx: -tol, dy: -tol).contains(p)
        case .ellipse(let r):
            let sr = r.scaled(sx, sy)
            let cx = sr.midX, cy = sr.midY
            let rx = sr.width / 2, ry = sr.height / 2
            let d = pow((p.x - cx) / max(rx, 1), 2) + pow((p.y - cy) / max(ry, 1), 2)
            return d <= 1.15
        case .blur(let r, _), .highlight(let r):
            return r.scaled(sx, sy).insetBy(dx: -tol, dy: -tol).contains(p)
        case .markerStroke(let pts):
            return MarkerStroke.hitTest(point: p, points: pts, width: ann.lineWidth, sx: sx, sy: sy)
        }
    }

    private func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx*dx + dy*dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x)*dx + (p.y - a.y)*dy) / len2))
        return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
    }

    private func drawSelectionBorder(_ ann: Annotation, in ctx: GraphicsContext, size: CGSize) {
        let sx = size.width / max(ann.canvasSize.width, 1)
        let sy = size.height / max(ann.canvasSize.height, 1)
        let style = StrokeStyle(lineWidth: 1, dash: [5, 4])
        let selColor = GraphicsContext.Shading.color(Color.white.opacity(0.9))
        switch ann.kind {
        case .arrow(let f, let t), .line(let f, let t):
            var p = Path()
            p.move(to: CGPoint(x: f.x*sx, y: f.y*sy))
            p.addLine(to: CGPoint(x: t.x*sx, y: t.y*sy))
            ctx.stroke(p, with: selColor, style: style)
        case .rect(let r), .rectFilled(let r), .ellipse(let r), .blur(let r, _), .highlight(let r):
            ctx.stroke(Path(r.scaled(sx, sy)), with: selColor, style: style)
        case .markerStroke:
            let pad = ann.lineWidth * (sx + sy) / 4
            ctx.stroke(Path(ann.kind.boundingRect.insetBy(dx: -pad, dy: -pad).scaled(sx, sy)), with: selColor, style: style)
        }
    }

    private func rectBetween(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func drawDraft(in context: GraphicsContext, size: CGSize) {
        if state.tool == .marker, !markerPoints.isEmpty {
            let path = MarkerStroke.path(from: markerPoints, scaleX: 1, scaleY: 1)
            context.stroke(
                path,
                with: .color(state.color.opacity(MarkerStroke.fillOpacity)),
                style: StrokeStyle(lineWidth: markerWidth, lineCap: .round, lineJoin: .round)
            )
            return
        }
        guard let s = dragStart, let c = dragCurrent else { return }
        let color = state.color, lw = state.lineWidth
        switch state.tool {
        case .arrow: drawArrow(from: s, to: c, color: color, lineWidth: lw, in: context)
        case .line:
            var p = Path(); p.move(to: s); p.addLine(to: c)
            context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        case .rect:
            context.stroke(Path(rectBetween(s, c)), with: .color(color), style: StrokeStyle(lineWidth: lw))
        case .rectFilled:
            context.fill(Path(rectBetween(s, c)), with: .color(color))
        case .ellipse:
            context.stroke(Path(ellipseIn: rectBetween(s, c)), with: .color(color), style: StrokeStyle(lineWidth: lw))
        case .blur:
            context.stroke(Path(rectBetween(s, c)), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .highlight:
            // The dim overlay shows the spotlight; add a thin border for clarity.
            context.stroke(Path(rectBetween(s, c)), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1))
        default: break
        }
    }

    private func drawAnnotation(_ ann: Annotation, in context: GraphicsContext, currentSize: CGSize) {
        let scaleX = currentSize.width / max(ann.canvasSize.width, 1)
        let scaleY = currentSize.height / max(ann.canvasSize.height, 1)
        let scale = (scaleX + scaleY) / 2
        let lw = ann.lineWidth * scale
        func sp(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scaleX, y: p.y * scaleY) }
        func sr(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scaleX, y: r.minY * scaleY, width: r.width * scaleX, height: r.height * scaleY) }
        switch ann.kind {
        case .arrow(let f, let t): drawArrow(from: sp(f), to: sp(t), color: ann.color, lineWidth: lw, in: context)
        case .line(let f, let t):
            var p = Path(); p.move(to: sp(f)); p.addLine(to: sp(t))
            context.stroke(p, with: .color(ann.color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        case .rect(let r): context.stroke(Path(sr(r)), with: .color(ann.color), style: StrokeStyle(lineWidth: lw))
        case .rectFilled(let r): context.fill(Path(sr(r)), with: .color(ann.color))
        case .ellipse(let r): context.stroke(Path(ellipseIn: sr(r)), with: .color(ann.color), style: StrokeStyle(lineWidth: lw))
        case .highlight(let r):
            // Subtle border around the spotlighted region; the dim overlay does the darkening.
            context.stroke(Path(sr(r)), with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1))
        case .markerStroke(let pts):
            let path = MarkerStroke.path(from: pts, scaleX: scaleX, scaleY: scaleY)
            context.stroke(
                path,
                with: .color(ann.color.opacity(MarkerStroke.fillOpacity)),
                style: StrokeStyle(lineWidth: ann.lineWidth * scale, lineCap: .round, lineJoin: .round)
            )
        case .blur: break   // rendered by blurOverlay
        }
    }

    private func drawArrow(from: CGPoint, to: CGPoint, color: Color, lineWidth: CGFloat, in context: GraphicsContext) {
        var path = Path(); path.move(to: from); path.addLine(to: to)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength: CGFloat = max(10, lineWidth * 3)
        let headAngle: CGFloat = .pi / 6
        let p1 = CGPoint(x: to.x - headLength * cos(angle - headAngle), y: to.y - headLength * sin(angle - headAngle))
        let p2 = CGPoint(x: to.x - headLength * cos(angle + headAngle), y: to.y - headLength * sin(angle + headAngle))
        var head = Path(); head.move(to: to); head.addLine(to: p1); head.move(to: to); head.addLine(to: p2)
        context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    // MARK: - Image picker

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let img = NSImage(contentsOf: url),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            state.addImage(cg)
        }
        state.tool = .select   // so the freshly added image can be moved immediately
    }
}

// MARK: - Placed image overlay

private struct ImageItemView: View {
    let item: ImageItem
    let canvasSize: CGSize
    @ObservedObject var state: EditorState

    @State private var dragStartCenter: CGPoint?
    @State private var dragStartWidth: CGFloat?

    private var width: CGFloat { item.widthNorm * canvasSize.width }
    private var height: CGFloat { width / item.aspect }
    private var center: CGPoint { CGPoint(x: item.centerNorm.x * canvasSize.width, y: item.centerNorm.y * canvasSize.height) }
    private var isSelected: Bool { state.selectedID == item.id }
    private var interactive: Bool { state.tool == .select }

    var body: some View {
        ZStack {
            Image(nsImage: item.displayImage)
                .resizable()
                .frame(width: width, height: height)
                .overlay(isSelected ? RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5) : nil)
        }
        .frame(width: width, height: height)
        .position(center)
        .allowsHitTesting(interactive)
        .onTapGesture { state.selectedID = item.id }
        .gesture(moveGesture)
        .overlay(alignment: .topLeading) { if isSelected && interactive { deleteButton } }
        .overlay(alignment: .bottomTrailing) { if isSelected && interactive { resizeHandle } }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                if dragStartCenter == nil { dragStartCenter = center; state.selectedID = item.id }
                let s = dragStartCenter!
                let c = CGPoint(x: s.x + v.translation.width, y: s.y + v.translation.height)
                state.updateImage(id: item.id, centerNorm: CGPoint(x: c.x / canvasSize.width, y: c.y / canvasSize.height))
            }
            .onEnded { _ in dragStartCenter = nil }
    }

    private var deleteButton: some View {
        Button { state.selectedID = item.id; state.deleteSelected() } label: {
            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, .black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .position(x: center.x - width / 2, y: center.y - height / 2)
    }

    private var resizeHandle: some View {
        Circle().fill(Color.accentColor).frame(width: 12, height: 12)
            .position(x: center.x + width / 2, y: center.y + height / 2)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if dragStartWidth == nil { dragStartWidth = width; state.selectedID = item.id }
                        let newW = (dragStartWidth ?? width) + v.translation.width
                        state.updateImage(id: item.id, widthNorm: newW / canvasSize.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

// MARK: - Text overlay

private struct TextItemView: View {
    let item: TextItem
    let canvasSize: CGSize
    @ObservedObject var state: EditorState
    @FocusState private var focused: Bool
    @State private var dragOffset: CGSize = .zero

    private var fontSize: CGFloat { item.fontFrac * canvasSize.height }
    private var center: CGPoint { CGPoint(x: item.centerNorm.x * canvasSize.width, y: item.centerNorm.y * canvasSize.height) }
    private var displayCenter: CGPoint {
        CGPoint(x: center.x + dragOffset.width, y: center.y + dragOffset.height)
    }
    private var isEditing: Bool { state.editingTextID == item.id }
    private var isSelected: Bool { state.selectedID == item.id }
    private var interactive: Bool { state.tool == .select }

    private var binding: Binding<String> {
        Binding(
            get: { item.text },
            set: { state.updateText(id: item.id, text: $0) }
        )
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("Text", text: binding)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(item.color)
                    .fixedSize()
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.15)))
                    .focused($focused)
                    .onSubmit { state.commitTextEditing() }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { state.commitTextEditing() }
                    }
            } else {
                Text(item.text.isEmpty ? " " : item.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(item.color)
                    .padding(2)
                    .overlay(isSelected ? RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1.5) : nil)
            }
        }
        .position(displayCenter)
        .allowsHitTesting(interactive || isEditing)
        .onTapGesture(count: 2) {
            guard interactive else { return }
            state.selectedID = item.id
            state.selectedAnnotationID = nil
            state.editingTextID = item.id
        }
        .onTapGesture(count: 1) {
            guard interactive else { return }
            state.commitTextEditing()
            state.selectedID = item.id
            state.selectedAnnotationID = nil
        }
        .gesture(interactive && !isEditing ? moveGesture : nil)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if state.selectedID != item.id { state.selectedID = item.id }
                dragOffset = v.translation
            }
            .onEnded { v in
                let c = CGPoint(x: center.x + v.translation.width, y: center.y + v.translation.height)
                state.updateText(id: item.id, centerNorm: CGPoint(x: c.x / canvasSize.width, y: c.y / canvasSize.height))
                dragOffset = .zero
            }
    }
}

// MARK: - CGRect helper

private extension CGRect {
    func scaled(_ sx: CGFloat, _ sy: CGFloat) -> CGRect {
        CGRect(x: minX * sx, y: minY * sy, width: width * sx, height: height * sy)
    }
}

// MARK: - Annotation selection overlay (select tool)

private struct AnnotationSelectionView: View {
    let annotation: Annotation
    let canvasSize: CGSize
    @ObservedObject var state: EditorState

    private let handleSize: CGFloat = 7
    private enum ACorner { case tl, tr, bl, br }

    @State private var resizeStart: CGRect?
    @State private var resizeCorner: ACorner?
    @State private var endFromStart: CGPoint?
    @State private var endToStart: CGPoint?

    private var sx: CGFloat { canvasSize.width / max(annotation.canvasSize.width, 1) }
    private var sy: CGFloat { canvasSize.height / max(annotation.canvasSize.height, 1) }

    private var scaledRect: CGRect? {
        switch annotation.kind {
        case .rect(let r), .rectFilled(let r), .ellipse(let r), .blur(let r, _), .highlight(let r):
            return r.scaled(sx, sy)
        case .markerStroke:
            let pad = annotation.lineWidth * (sx + sy) / 4
            return annotation.kind.boundingRect.insetBy(dx: -pad, dy: -pad).scaled(sx, sy)
        default: return nil
        }
    }

    private var allowsResize: Bool { !annotation.kind.isMarker }

    private var endpoints: (CGPoint, CGPoint)? {
        switch annotation.kind {
        case .arrow(let f, let t), .line(let f, let t):
            return (CGPoint(x: f.x*sx, y: f.y*sy), CGPoint(x: t.x*sx, y: t.y*sy))
        default: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let r = scaledRect {
                selectionOutline(r)
                if allowsResize {
                    cornerHandle(.tl, at: CGPoint(x: r.minX, y: r.minY))
                    cornerHandle(.tr, at: CGPoint(x: r.maxX, y: r.minY))
                    cornerHandle(.bl, at: CGPoint(x: r.minX, y: r.maxY))
                    cornerHandle(.br, at: CGPoint(x: r.maxX, y: r.maxY))
                }
                deleteBtn(at: CGPoint(x: r.maxX + 10, y: r.minY - 10))
            }
            if let (f, t) = endpoints {
                endpointHandle(isFrom: true, at: f)
                endpointHandle(isFrom: false, at: t)
                deleteBtn(at: CGPoint(x: max(f.x, t.x) + 10, y: min(f.y, t.y) - 10))
            }
        }
    }

    private func selectionOutline(_ r: CGRect) -> some View {
        Rectangle()
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    private func cornerHandle(_ corner: ACorner, at pt: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .frame(width: handleSize, height: handleSize)
            .contentShape(Rectangle().size(width: handleSize * 2.8, height: handleSize * 2.8))
            .position(pt)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if resizeStart == nil, let r = scaledRect {
                            resizeStart = r; resizeCorner = corner
                        }
                        guard let start = resizeStart else { return }
                        let c = resizeCorner ?? corner
                        let newRect = applyCorner(c, start: start, tx: v.translation.width, ty: v.translation.height)
                        state.resizeAnnotationRect(id: annotation.id, newRect: newRect, canvasSize: canvasSize)
                    }
                    .onEnded { _ in resizeStart = nil; resizeCorner = nil }
            )
    }

    private func applyCorner(_ c: ACorner, start: CGRect, tx: CGFloat, ty: CGFloat) -> CGRect {
        let min: CGFloat = 10
        switch c {
        case .tl: return CGRect(x: start.minX+tx, y: start.minY+ty, width: max(start.width-tx,min), height: max(start.height-ty,min))
        case .tr: return CGRect(x: start.minX,    y: start.minY+ty, width: max(start.width+tx,min), height: max(start.height-ty,min))
        case .bl: return CGRect(x: start.minX+tx, y: start.minY,    width: max(start.width-tx,min), height: max(start.height+ty,min))
        case .br: return CGRect(x: start.minX,    y: start.minY,    width: max(start.width+tx,min), height: max(start.height+ty,min))
        }
    }

    private func endpointHandle(isFrom: Bool, at pt: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
            .frame(width: handleSize, height: handleSize)
            .contentShape(Rectangle().size(width: handleSize * 2.8, height: handleSize * 2.8))
            .position(pt)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if isFrom {
                            if endFromStart == nil { endFromStart = pt }
                            let s = endFromStart ?? pt
                            let np = CGPoint(x: s.x + v.translation.width, y: s.y + v.translation.height)
                            state.updateAnnotationEndpoints(id: annotation.id, newFrom: np, canvasSize: canvasSize)
                        } else {
                            if endToStart == nil { endToStart = pt }
                            let s = endToStart ?? pt
                            let np = CGPoint(x: s.x + v.translation.width, y: s.y + v.translation.height)
                            state.updateAnnotationEndpoints(id: annotation.id, newTo: np, canvasSize: canvasSize)
                        }
                    }
                    .onEnded { _ in endFromStart = nil; endToStart = nil }
            )
    }

    private func deleteBtn(at pt: CGPoint) -> some View {
        Button {
            state.selectedAnnotationID = annotation.id
            state.deleteSelected()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .position(pt)
    }
}

// MARK: - Interactive crop overlay

private struct CropOverlay: View {
    @Binding var norm: CGRect
    let canvasSize: CGSize
    let ratio: CGFloat?

    @State private var dragPhase: DragPhase = .idle
    @State private var createOrigin: CGPoint = .zero
    @State private var anchorNorm: CGRect = .zero
    @State private var anchorRect: CGRect = .zero
    @State private var activeCorner: Corner?

    private enum DragPhase { case idle, creating, moving, resizing }
    private enum Corner { case tl, tr, bl, br }

    private let handle: CGFloat = 8
    private let handleHit: CGFloat = 14
    private let minSizePts: CGFloat = 30

    private var hasSelection: Bool { norm.width > 0.001 && norm.height > 0.001 }
    private var showCutout: Bool { hasSelection || dragPhase == .creating }

    private var rect: CGRect {
        CGRect(x: norm.minX * canvasSize.width, y: norm.minY * canvasSize.height,
               width: norm.width * canvasSize.width, height: norm.height * canvasSize.height)
    }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                if showCutout, rect.width > 0.5, rect.height > 0.5 {
                    var outside = Path(CGRect(origin: .zero, size: size))
                    outside.addRect(rect)
                    ctx.fill(outside, with: .color(.black.opacity(0.52)), style: FillStyle(eoFill: true))
                    ctx.stroke(Path(rect), with: .color(.white.opacity(0.95)), lineWidth: 1.5)
                } else {
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.52)))
                }
            }
            .allowsHitTesting(false)

            // One full-canvas gesture — never shrinks to the selection box mid-drag.
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .gesture(cropGesture)

            if hasSelection && dragPhase != .creating {
                handleDot().position(x: rect.minX, y: rect.minY)
                handleDot().position(x: rect.maxX, y: rect.minY)
                handleDot().position(x: rect.minX, y: rect.maxY)
                handleDot().position(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private var cropGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragPhase == .idle { beginDrag(at: v.startLocation) }
                updateDrag(v)
            }
            .onEnded { _ in finishDrag() }
    }

    private func beginDrag(at point: CGPoint) {
        if let corner = hitCorner(point) {
            dragPhase = .resizing
            activeCorner = corner
            anchorRect = rect
        } else if hasSelection && rect.insetBy(dx: -6, dy: -6).contains(point) {
            dragPhase = .moving
            anchorNorm = norm
        } else {
            dragPhase = .creating
            createOrigin = point
            norm = .zero
        }
    }

    private func updateDrag(_ v: DragGesture.Value) {
        switch dragPhase {
        case .creating:
            let x0 = min(createOrigin.x, v.location.x), y0 = min(createOrigin.y, v.location.y)
            let w = abs(v.location.x - createOrigin.x), h = abs(v.location.y - createOrigin.y)
            norm = normalize(
                CGRect(x: x0, y: y0, width: w, height: h)
                    .intersection(CGRect(origin: .zero, size: canvasSize))
            )
        case .moving:
            var x = anchorNorm.minX + v.translation.width / canvasSize.width
            var y = anchorNorm.minY + v.translation.height / canvasSize.height
            x = min(max(0, x), 1 - anchorNorm.width)
            y = min(max(0, y), 1 - anchorNorm.height)
            norm = CGRect(x: x, y: y, width: anchorNorm.width, height: anchorNorm.height)
        case .resizing:
            guard let corner = activeCorner else { return }
            norm = normalize(resize(corner, from: anchorRect, translation: v.translation))
        case .idle:
            break
        }
    }

    private func finishDrag() {
        defer { dragPhase = .idle; activeCorner = nil }
        guard dragPhase != .idle else { return }
        if norm.width < 0.005 || norm.height < 0.005 {
            norm = .zero
            return
        }
        if let ratio, ratio > 0 {
            norm = fitRatio(norm, ratio: ratio)
        }
    }

    private func hitCorner(_ p: CGPoint) -> Corner? {
        guard hasSelection else { return nil }
        let pts: [(Corner, CGPoint)] = [
            (.tl, CGPoint(x: rect.minX, y: rect.minY)),
            (.tr, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bl, CGPoint(x: rect.minX, y: rect.maxY)),
            (.br, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for (c, pt) in pts where abs(p.x - pt.x) <= handleHit && abs(p.y - pt.y) <= handleHit {
            return c
        }
        return nil
    }

    private func handleDot() -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.3), lineWidth: 0.75))
            .frame(width: handle, height: handle)
            .allowsHitTesting(false)
    }

    private func fitRatio(_ n: CGRect, ratio: CGFloat) -> CGRect {
        let W = canvasSize.width, H = canvasSize.height
        var w = n.width * W, h = n.height * H
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        let x = n.minX * W + (n.width * W - w) / 2
        let y = n.minY * H + (n.height * H - h) / 2
        return normalize(CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(origin: .zero, size: canvasSize)))
    }

    private func resize(_ corner: Corner, from start: CGRect, translation: CGSize) -> CGRect {
        let tx = translation.width, ty = translation.height
        let anchor: CGPoint
        var moving: CGPoint
        switch corner {
        case .br: anchor = CGPoint(x: start.minX, y: start.minY); moving = CGPoint(x: start.maxX + tx, y: start.maxY + ty)
        case .tr: anchor = CGPoint(x: start.minX, y: start.maxY); moving = CGPoint(x: start.maxX + tx, y: start.minY + ty)
        case .bl: anchor = CGPoint(x: start.maxX, y: start.minY); moving = CGPoint(x: start.minX + tx, y: start.maxY + ty)
        case .tl: anchor = CGPoint(x: start.maxX, y: start.maxY); moving = CGPoint(x: start.minX + tx, y: start.minY + ty)
        }
        var w = max(abs(moving.x - anchor.x), minSizePts)
        var h = max(abs(moving.y - anchor.y), minSizePts)
        if let ratio, ratio > 0 { h = w / ratio }
        let maxW = moving.x >= anchor.x ? canvasSize.width - anchor.x : anchor.x
        let maxH = moving.y >= anchor.y ? canvasSize.height - anchor.y : anchor.y
        if w > maxW { w = maxW; if let ratio, ratio > 0 { h = w / ratio } }
        if h > maxH { h = maxH; if let ratio, ratio > 0 { w = h * ratio } }
        let originX = moving.x >= anchor.x ? anchor.x : anchor.x - w
        let originY = moving.y >= anchor.y ? anchor.y : anchor.y - h
        return CGRect(x: originX, y: originY, width: w, height: h)
    }

    private func normalize(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / canvasSize.width, y: r.minY / canvasSize.height,
               width: r.width / canvasSize.width, height: r.height / canvasSize.height)
    }
}

// MARK: - Color palette popover

private struct ColorPalettePopover: View {
    @Binding var selection: Color
    private static let colors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue,
        .indigo, .purple, .pink, .black, .white, .gray, .brown
    ]
    private let cols = Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5)

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(Array(Self.colors.enumerated()), id: \.offset) { _, c in
                    Button { selection = c } label: {
                        Circle().fill(c).frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(selection == c ? Color.accentColor : .white.opacity(0.25), lineWidth: selection == c ? 2 : 1))
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            ColorPicker("Custom", selection: $selection, supportsOpacity: false).font(.system(size: 11))
        }
        .padding(12)
        .frame(width: 196)
    }
}

// MARK: - Toolbar buttons

private struct ToolButton: View {
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.82))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : (hovered ? Color.white.opacity(0.14) : Color.clear)))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}

private struct IconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? Color.white.opacity(0.14) : Color.clear))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}

private struct BarTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
    }
}

private struct BarPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1.0)))
    }
}
