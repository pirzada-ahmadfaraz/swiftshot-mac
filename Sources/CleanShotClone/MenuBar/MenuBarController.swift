import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onCaptureArea: () -> Void
    private let onCaptureWindow: () -> Void
    private let onCaptureFullScreen: () -> Void
    private let onCaptureScrolling: () -> Void
    private let onCaptureText: () -> Void
    private let onToggleRecording: () -> Void
    private let onOpenHistory: () -> Void
    private let onOpenPreferences: () -> Void
    private let isRecordingProvider: () -> Bool

    init(
        onCaptureArea: @escaping () -> Void,
        onCaptureWindow: @escaping () -> Void,
        onCaptureFullScreen: @escaping () -> Void,
        onCaptureScrolling: @escaping () -> Void,
        onCaptureText: @escaping () -> Void,
        onToggleRecording: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onOpenPreferences: @escaping () -> Void,
        isRecording: @escaping () -> Bool
    ) {
        self.onCaptureArea = onCaptureArea
        self.onCaptureWindow = onCaptureWindow
        self.onCaptureFullScreen = onCaptureFullScreen
        self.onCaptureScrolling = onCaptureScrolling
        self.onCaptureText = onCaptureText
        self.onToggleRecording = onToggleRecording
        self.onOpenHistory = onOpenHistory
        self.onOpenPreferences = onOpenPreferences
        self.isRecordingProvider = isRecording
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SwiftShot") {
                image.isTemplate = true
                button.image = image
            } else {
                // Guarantee a visible footprint even if the symbol fails to load.
                button.title = "📷"
            }
            button.toolTip = "SwiftShot — ⌥⇧4 area · ⌥⇧5 scroll · ⌥⇧1 text · ⌥⇧3 full · ⌥⇧2 window · ⌥⇧6 record"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem(title: "Capture Area", key: "4", modifiers: [.option, .shift], action: #selector(triggerArea)))
        menu.addItem(makeItem(title: "Capture Window", key: "2", modifiers: [.option, .shift], action: #selector(triggerWindow)))
        menu.addItem(makeItem(title: "Capture Full Screen", key: "3", modifiers: [.option, .shift], action: #selector(triggerFull)))
        menu.addItem(makeScrollingItem())
        menu.addItem(makeSymbolItem(title: "Capture Text", symbol: "textformat", key: "1", action: #selector(triggerText)))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Record Screen", key: "6", modifiers: [.option, .shift], action: #selector(triggerRecord)))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Capture History…", key: "", modifiers: [], action: #selector(triggerHistory)))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Preferences…", key: ",", modifiers: [.command], action: #selector(openPreferences)))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Quit", key: "q", modifiers: [.command], action: #selector(quit)))

        statusItem.menu = menu
    }

    func refreshState() {
        guard let button = statusItem.button else { return }
        if isRecordingProvider() {
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SwiftShot")
            button.image?.isTemplate = true
            button.contentTintColor = nil
            setRecordingElapsed(nil)
        }
    }

    /// Show the elapsed recording time next to the status icon (nil clears it).
    func setRecordingElapsed(_ text: String?) {
        guard let button = statusItem.button else { return }
        if let text {
            button.attributedTitle = NSAttributedString(
                string: " \(text)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.systemRed,
                    .baselineOffset: 1
                ]
            )
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if let recordItem = menu.items.first(where: { $0.action == #selector(triggerRecord) }) {
            recordItem.title = isRecordingProvider() ? "Stop Recording" : "Record Screen"
        }
    }

    // MARK: - Actions

    @objc private func triggerArea() { onCaptureArea() }
    @objc private func triggerWindow() { onCaptureWindow() }
    @objc private func triggerFull() { onCaptureFullScreen() }
    @objc private func triggerScrolling() { onCaptureScrolling() }
    @objc private func triggerText() { onCaptureText() }
    @objc private func triggerRecord() { onToggleRecording() }
    @objc private func triggerHistory() { onOpenHistory() }
    @objc private func openPreferences() { onOpenPreferences() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func makeScrollingItem() -> NSMenuItem {
        makeSymbolItem(title: "Scrolling Capture", symbol: "arrow.down.to.line.compact", key: "5", action: #selector(triggerScrolling))
    }

    private func makeSymbolItem(title: String, symbol: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.option, .shift]
        item.target = self
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            item.image = img
        }
        return item
    }

    private func makeItem(title: String, key: String, modifiers: NSEvent.ModifierFlags, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }
}
