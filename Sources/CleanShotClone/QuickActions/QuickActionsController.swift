import AppKit

/// Manages a vertical LIST of screenshot cards in the bottom-left corner.
/// New captures push older ones up; cards persist until acted on (copied / saved /
/// pinned / edited / closed / swiped left). There is no time-based dismissal.
@MainActor
final class QuickActionsController {
    private var cards: [ScreenshotCardController] = []
    private var anchorScreen: NSScreen?
    private let margin: CGFloat = 24
    private let spacing: CGFloat = 18
    private let maxCards = 6

    func present(
        image: CGImage,
        originRectGlobal: CGRect?,
        onCopy: @escaping (CGImage) -> Void,
        onSave: @escaping (CGImage) -> Void,
        onPin: @escaping (CGImage, CGRect?) -> Void,
        onEdit: @escaping (CGImage) -> Void,
        onCloud: @escaping (CGImage) -> Void,
        onRedact: @escaping (CGImage) -> Void
    ) {
        guard let screen = originRectGlobal.flatMap({ Coords.screen(containing: $0) })
            ?? Coords.screenUnderMouse()
            ?? NSScreen.screens.first else { return }

        anchorScreen = screen

        let controller = ScreenshotCardController(
            image: image,
            pinAtGlobalRect: originRectGlobal,
            onCopy: { onCopy(image) },
            onSave: { onSave(image) },
            onPin: { frame in onPin(image, frame) },
            onEdit: { onEdit(image) },
            onCloud: { onCloud(image) },
            onRedact: { onRedact(image) }
        )
        append(controller, on: screen)
    }

    /// Card for a finished recording (video or GIF).
    func presentMedia(
        thumbnail: CGImage,
        url: URL,
        onCopy: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onTrim: @escaping () -> Void
    ) {
        guard let screen = Coords.screenUnderMouse() ?? NSScreen.screens.first else { return }
        anchorScreen = screen

        let controller = ScreenshotCardController(
            mediaThumbnail: thumbnail,
            mediaURL: url,
            onCopy: onCopy,
            onSave: onSave,
            onTrim: onTrim
        )
        append(controller, on: screen)
    }

    private func append(_ controller: ScreenshotCardController, on screen: NSScreen) {
        controller.onRequestClose = { [weak self] c in self?.remove(c) }

        cards.append(controller)

        if cards.count > maxCards {
            let oldest = cards.removeFirst()
            oldest.close(animated: true) {}
        }

        // Move existing cards to their new slots; fade the new card in at its slot.
        let origins = slotOrigins(on: screen)
        for (controller, origin) in zip(cards, origins) {
            if controller === cards.last {
                controller.show(at: origin)
            } else {
                controller.move(to: origin, animated: true)
            }
        }
    }

    private func remove(_ controller: ScreenshotCardController) {
        guard let idx = cards.firstIndex(where: { $0 === controller }) else { return }
        cards.remove(at: idx)
        controller.close(animated: true) {}
        relayout()
    }

    private func relayout() {
        guard let screen = anchorScreen ?? Coords.screenUnderMouse() ?? NSScreen.screens.first else { return }
        let origins = slotOrigins(on: screen)
        for (controller, origin) in zip(cards, origins) {
            controller.move(to: origin, animated: true)
        }
    }

    /// One origin per card, in `cards` order. The OLDEST (index 0) sits at the bottom and
    /// stays put; each newer card stacks above it. So `cards.last` is highest on screen.
    private func slotOrigins(on screen: NSScreen) -> [NSPoint] {
        let x = screen.visibleFrame.minX + margin
        let h = ScreenshotCardController.cardSize.height
        return cards.indices.map { idx in
            let y = screen.visibleFrame.minY + margin + CGFloat(idx) * (h + spacing)
            return NSPoint(x: x, y: y)
        }
    }
}
