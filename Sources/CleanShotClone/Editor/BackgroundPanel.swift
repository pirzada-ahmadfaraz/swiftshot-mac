import SwiftUI

/// Compact left sidebar for the background tool.
struct BackgroundPanel: View {
    @ObservedObject var state: EditorState
    let onAddWallpaper: () -> Void

    @State private var showAllGradients = false

    private let gridCols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 5)
    private let colorCols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 8)
    private static let plainColors: [Color] = [
        .black, .white, .gray, .red, .orange, .yellow, .green, .mint,
        .teal, .cyan, .blue, .indigo, .purple, .pink, .brown, Color(white: 0.4)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            presetsRow
            noneButton
            gradients
            wallpapers
            blurred
            plainColors
            Divider().padding(.vertical, 1)
            paddingControl
            insetRow
            shadowCornersRow
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: state.bgKind)           { state.invalidateFlatCache(); state.updateBgPreview() }
        .onChange(of: state.bgGradientIndex)  { state.updateBgPreview() }
        .onChange(of: state.bgBlurredVariant) { state.updateBgPreview() }
        .onChange(of: state.bgPlain)          { state.updateBgPreview() }
        .onChange(of: state.bgWallpaper)      { state.invalidateFlatCache(); state.updateBgPreview() }
        .onChange(of: state.bgPadding)        { state.updateBgPreview() }
        .onChange(of: state.bgCorners)        { state.updateBgPreview() }
        .onChange(of: state.bgShadow)         { state.updateBgPreview() }
        .onChange(of: state.bgInset)          { state.updateBgPreview() }
    }

    // MARK: - Sections

    private var presetsRow: some View {
        HStack(spacing: 6) {
            Menu("Presets…") { Text("No saved presets") }
                .menuStyle(.borderlessButton).controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.18)))
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.18)))
        }
    }

    private var noneButton: some View {
        Button {
            guard state.bgKind != .none else { return }
            state.recordBackgroundUndo()
            state.bgKind = .none
            state.bgPreview = nil
        } label: {
            Text("None").font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(state.bgKind == .none ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(state.bgKind == .none ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var gradients: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                sectionTitle("Gradients")
                Spacer()
                Button(showAllGradients ? "Show less" : "Show more") { showAllGradients.toggle() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: gridCols, spacing: 5) {
                ForEach(0..<(showAllGradients ? EditorState.gradientCount : min(10, EditorState.gradientCount)), id: \.self) { i in
                    gradientSwatch(i)
                }
            }
        }
    }

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Wallpapers")
            HStack(spacing: 5) {
                if let wp = state.bgWallpaper { wallpaperSwatch(wp) }
                Button(action: onAddWallpaper) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary)
                        .frame(width: 30, height: 26)
                        .overlay(Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.secondary))
                }.buttonStyle(.plain)
                Spacer()
            }
        }
    }

    private var blurred: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Blurred")
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { v in blurredSwatch(v) }
                Spacer()
            }
        }
    }

    private var plainColors: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Plain color")
            LazyVGrid(columns: colorCols, spacing: 5) {
                ForEach(Array(Self.plainColors.enumerated()), id: \.offset) { _, c in plainSwatch(c) }
            }
            ColorPicker("Custom", selection: $state.bgPlain, supportsOpacity: false)
                .font(.system(size: 10)).controlSize(.mini)
                .onChange(of: state.bgPlain) {
                    state.recordBackgroundUndo()
                    state.bgKind = .plain
                }
        }
    }

    private var paddingControl: some View {
        labeledSlider("Padding", value: $state.bgPadding, range: 0...0.25)
            .onChange(of: state.bgPadding) { state.bgAutoBalance = false }
    }

    private var insetRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            labeledSlider("Inset", value: $state.bgInset, range: 0...0.3)
            Toggle("Auto-balance", isOn: $state.bgAutoBalance)
                .toggleStyle(.checkbox).font(.system(size: 10)).fixedSize()
                .onChange(of: state.bgAutoBalance) { _, on in
                    if on { state.applyAutoBalance() }
                    state.refreshBgPreviewNow()
                }
        }
    }

    private var shadowCornersRow: some View {
        HStack(spacing: 12) {
            labeledSlider("Shadow", value: $state.bgShadow, range: 0...1)
            labeledSlider("Corners", value: $state.bgCorners, range: 0...1)
        }
    }

    // MARK: - Swatches & helpers

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func gradientSwatch(_ i: Int) -> some View {
        let selected = state.bgKind == .gradient && state.bgGradientIndex == i
        return Button {
            state.recordBackgroundUndo()
            state.bgGradientIndex = i
            state.bgKind = .gradient
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: EditorState.gradientColors(i), startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 2 : 0.5))
        }.buttonStyle(.plain)
    }

    private func wallpaperSwatch(_ cg: CGImage) -> some View {
        let selected = state.bgKind == .wallpaper
        return Button {
            state.recordBackgroundUndo()
            state.bgKind = .wallpaper
        } label: {
            Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                .resizable().aspectRatio(contentMode: .fill).frame(width: 30, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 2 : 0.5))
        }.buttonStyle(.plain)
    }

    private func blurredSwatch(_ variant: Int) -> some View {
        let selected = state.bgKind == .blurred && state.bgBlurredVariant == variant
        let tint: Color? = variant == 1 ? .black.opacity(0.4) : (variant == 2 ? .white.opacity(0.4) : nil)
        return Button {
            state.recordBackgroundUndo()
            state.bgKind = .blurred
            state.bgBlurredVariant = variant
        } label: {
            Image(nsImage: state.displayImage)
                .resizable().aspectRatio(contentMode: .fill).frame(width: 30, height: 26).blur(radius: 4)
                .overlay(tint.map { Rectangle().fill($0) })
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: selected ? 2 : 0.5))
        }.buttonStyle(.plain)
    }

    private func plainSwatch(_ c: Color) -> some View {
        let selected = state.bgKind == .plain && state.bgPlain == c
        return Button {
            state.recordBackgroundUndo()
            state.bgPlain = c
            state.bgKind = .plain
        } label: {
            Circle().fill(c).frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.25), lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain)
    }

    private func labeledSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionTitle(title)
            Slider(value: value, in: range).controlSize(.mini)
        }
    }
}
