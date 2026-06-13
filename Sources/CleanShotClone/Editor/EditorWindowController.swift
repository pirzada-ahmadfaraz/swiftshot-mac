import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// Called when the user presses Done — hands back the flattened edited image so it can
    /// be re-presented as a card in the bottom-left stack.
    var onDoneEditing: ((CGImage) -> Void)?
    private let state: EditorState
    private var window: NSWindow?

    init(image: CGImage) {
        self.state = EditorState(cgImage: image)
        super.init()
    }

    func show() {
        let view = EditorView(
            state: state,
            onSaveAs: { [weak self] in self?.saveAs() },
            onDone: { [weak self] in self?.done() }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = []

        let initialSize = initialWindowSize()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Editor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Let the blue toolbar paint right up to the traffic lights.
        window.isMovableByWindowBackground = false
        window.contentViewController = hosting
        window.setContentSize(initialSize)
        // Must match the SwiftUI root's min frame, or the content gets clipped on open
        // (which was hiding the toolbar until a manual resize).
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func saveAs() {
        let composited = state.finalImage()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Edited Screenshot.png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: composited)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            do {
                try data.write(to: url)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Could not save screenshot"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    /// Done = bake the edits and send the result back as a card, then close the editor.
    private func done() {
        let composited = state.finalImage()
        onDoneEditing?(composited)
        window?.close()
    }

    private func initialWindowSize() -> NSSize {
        let toolbarHeight: CGFloat = 52
        let padding: CGFloat = 36
        let maxW: CGFloat = 1200
        let maxH: CGFloat = 760

        let imgW = state.pixelSize.width / 2
        let imgH = state.pixelSize.height / 2
        guard imgW > 0, imgH > 0 else { return NSSize(width: 800, height: 600) }

        let availW = maxW - padding
        let availH = maxH - toolbarHeight - padding
        let scale = min(availW / imgW, availH / imgH, 1)
        let drawW = imgW * scale
        let drawH = imgH * scale

        return NSSize(
            width: max(drawW + padding, 860),
            height: max(drawH + toolbarHeight + padding, 620)
        )
    }
}
