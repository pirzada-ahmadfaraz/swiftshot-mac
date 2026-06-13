import SwiftUI

/// Drives a single screenshot card. Hover state is pushed in from the AppKit
/// CardView's tracking area so the whole card (not just button rects) toggles it.
@MainActor
final class CardModel: ObservableObject {
    @Published var hovering = false
    /// When pinned, the buttons stay visible permanently and there's no dim overlay.
    @Published var pinned = false
    /// Media (video/GIF) cards: pin is hidden and the edit slot becomes Trim (scissors).
    var isMedia = false
    let image: NSImage
    let horizontalActions: Bool

    var onCopy: () -> Void = {}
    var onSave: () -> Void = {}
    var onPin: () -> Void = {}
    var onEdit: () -> Void = {}
    var onClose: () -> Void = {}
    var onCloud: () -> Void = {}
    var onRedact: () -> Void = {}

    init(image: NSImage, horizontalActions: Bool) {
        self.image = image
        self.horizontalActions = horizontalActions
    }
}

/// Transparent overlay drawn on top of the AppKit image layer. Only the buttons are
/// hit-testable; empty areas fall through to the CardView so swipe/drag still works.
struct CardButtonsOverlay: View {
    @ObservedObject var model: CardModel

    private var showButtons: Bool { model.hovering || model.pinned }
    private var showDim: Bool { model.hovering && !model.pinned }

    var body: some View {
        ZStack {
            if showButtons {
                if showDim {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.32))
                        .allowsHitTesting(false)
                }

                VStack {
                    HStack {
                        // A pinned card is already pinned — hide the pin button there.
                        // Media cards can't be pinned at all.
                        if model.pinned || model.isMedia {
                            Color.clear.frame(width: 22, height: 22)
                        } else {
                            CornerButton(systemName: "pin.fill", action: model.onPin)
                                .rotationEffect(.degrees(-45))
                        }
                        Spacer()
                        CornerButton(systemName: "xmark", action: model.onClose)
                    }
                    Spacer()
                    HStack {
                        // Media cards trim (scissors); screenshots edit (pencil).
                        CornerButton(systemName: model.isMedia ? "scissors" : "pencil", action: model.onEdit)
                        Spacer()
                        // Redact + cloud upload are image-only — recordings/GIFs are
                        // too large to host and have no redaction flow.
                        if !model.isMedia {
                            CornerButton(systemName: "eye.slash", action: model.onRedact)
                            CornerButton(systemName: "icloud.and.arrow.up", action: model.onCloud)
                        }
                    }
                }
                .padding(8)

                actionButtons
            }
        }
        .animation(.easeInOut(duration: 0.12), value: model.hovering)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if model.horizontalActions {
            HStack(spacing: 8) {
                PillButton(title: "Copy", action: model.onCopy)
                PillButton(title: "Save", action: model.onSave)
            }
        } else {
            VStack(spacing: 8) {
                PillButton(title: "Copy", action: model.onCopy)
                PillButton(title: "Save", action: model.onSave)
            }
        }
    }
}

private struct CornerButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hovered ? 0.98 : 0.9))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.78))
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 84, height: 28)
                .background(
                    Capsule().fill(Color.white.opacity(hovered ? 1.0 : 0.92))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
