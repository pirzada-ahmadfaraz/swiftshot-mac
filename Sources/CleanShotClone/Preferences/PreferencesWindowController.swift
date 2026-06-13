import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Floating Preferences window — General / Output / Shortcuts tabs.
/// Mirrors `RecordingSettingsPanel`: a `@MainActor` singleton holding one reusable
/// `NSWindow` backed by an `NSHostingController`.
@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    /// Invoked whenever a keyboard shortcut row changes, so `AppDelegate` can
    /// re-register the global hotkeys from the freshly-saved prefs.
    var onHotkeysChanged: (() -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = PreferencesRootView(onHotkeysChanged: { [weak self] in self?.onHotkeysChanged?() })
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 560, height: 480))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Store

/// Wraps `AppPreferences`, persisting on every mutation (mirrors RecordingSettingsPanel's
/// private SettingsStore). Side effects that must fire on a *specific* field change
/// (launch-at-login registration) are handled in the views via `.onChange`.
private final class SettingsStore: ObservableObject {
    @Published var s: AppPreferences {
        didSet { s.save() }
    }
    init() { s = AppPreferences.load() }
}

// MARK: - Root

private struct PreferencesRootView: View {
    let onHotkeysChanged: () -> Void
    @StateObject private var store = SettingsStore()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text("Output").tag(1)
                Text("Shortcuts").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .padding(.top, 14)

            Group {
                switch tab {
                case 0: GeneralTab(store: store)
                case 1: OutputTab(store: store)
                default: ShortcutsTab(store: store, onHotkeysChanged: onHotkeysChanged)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsGrid {
            row("After capture:") {
                Picker("", selection: $store.s.afterCaptureBehavior.rawBinding) {
                    ForEach(AppPreferences.AfterCaptureBehavior.allCases, id: \.rawValue) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 230)
            }
            row("Clipboard:") {
                Toggle("Also copy to clipboard when showing the card", isOn: $store.s.copyToClipboardAlso)
            }
            row("Sounds:") {
                Toggle("Play sound effects", isOn: $store.s.playSounds)
            }
            row("Startup:") {
                Toggle("Launch at login", isOn: $store.s.launchAtLogin)
                    .onChange(of: store.s.launchAtLogin) { _, on in
                        LaunchAtLogin.set(on)
                    }
            }
            row("Recording:") {
                Button("Recording Settings…") {
                    RecordingSettingsPanel.shared.show()
                }
            }
        }
    }
}

// MARK: - Output tab

private struct OutputTab: View {
    @ObservedObject var store: SettingsStore

    private var previewName: String {
        let rendered = FilenameTemplate.render(
            template: store.s.filenameTemplate,
            date: Date(),
            appName: "Safari",
            sequence: 1
        )
        return FilenameTemplate.sanitized(rendered) + "." + store.s.imageFormat.fileExtension
    }

    var body: some View {
        ScrollView {
            SettingsGrid {
                row("Save to:") {
                    HStack(spacing: 8) {
                        Text(store.s.saveLocationURL.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 230, alignment: .leading)
                        Button("Choose…") { chooseSaveFolder() }
                    }
                }
                row("Format:") {
                    Picker("", selection: $store.s.imageFormat.rawBinding) {
                        ForEach(AppPreferences.ImageFormat.allCases, id: \.rawValue) { fmt in
                            Text(fmt.label).tag(fmt.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                if store.s.imageFormat == .jpg {
                    row("Quality:") {
                        HStack(spacing: 8) {
                            Slider(value: $store.s.jpgQuality, in: 0.1...1.0)
                                .frame(width: 180)
                            Text("\(Int(store.s.jpgQuality * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                row("Filename:") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("", text: $store.s.filenameTemplate)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                        Text(previewName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Tokens: {date} {time} {datetime} {app} {seq} {uuid}")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Divider().padding(.vertical, 12)

            cloudSection
        }
    }

    // MARK: Cloud / Sharing

    private var cloudSection: some View {
        SettingsGrid {
            row("Sharing:") {
                Picker("", selection: $store.s.cloudProvider.rawBinding) {
                    ForEach(AppPreferences.CloudProvider.allCases, id: \.rawValue) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            if store.s.cloudProvider == .localFolder {
                row("Public folder:") {
                    HStack(spacing: 8) {
                        Text(store.s.cloudFolderURL?.path ?? "~/Public/SwiftShot")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 200, alignment: .leading)
                        Button("Choose…") { chooseCloudFolder() }
                    }
                }
                row("Base URL:") {
                    TextField("https://example.com/shots", text: $store.s.cloudPublicBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
            } else {
                row("Endpoint:") {
                    TextField("https://api.example.com/upload", text: $store.s.cloudEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                row("Bearer token:") {
                    TextField("optional", text: $store.s.cloudToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                row("Response URL key:") {
                    TextField("url", text: $store.s.cloudResponseURLKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }
            }
        }
    }

    // MARK: Folder pickers (store security-scoped bookmarks)

    private func chooseSaveFolder() {
        guard let url = openFolderPanel(title: "Choose Save Folder") else { return }
        store.s.saveLocationBookmark = Self.bookmark(for: url)
    }

    private func chooseCloudFolder() {
        guard let url = openFolderPanel(title: "Choose Public Folder") else { return }
        store.s.cloudFolderBookmark = Self.bookmark(for: url)
    }

    private func openFolderPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func bookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            Log.error("Could not bookmark \(url.path): \(error)", log: Log.general)
            return nil
        }
    }
}

// MARK: - Shortcuts tab

private struct ShortcutsTab: View {
    @ObservedObject var store: SettingsStore
    let onHotkeysChanged: () -> Void

    /// Stable display order for the shortcut rows.
    private let orderedActions: [(HotKeyAction, String)] = [
        (.captureArea,       "Capture Area"),
        (.captureWindow,     "Capture Window"),
        (.captureFullScreen, "Capture Full Screen"),
        (.captureScrolling,  "Scrolling Capture"),
        (.captureText,       "Capture Text"),
        (.toggleRecording,   "Record Screen"),
    ]

    var body: some View {
        SettingsGrid {
            ForEach(orderedActions, id: \.0.rawValue) { action, label in
                row(label + ":") {
                    ShortcutRecorder(
                        combo: comboBinding(for: action)
                    )
                    .frame(width: 150, height: 24)
                }
            }
        }
    }

    private func comboBinding(for action: HotKeyAction) -> Binding<AppPreferences.HotKeyCombo> {
        Binding<AppPreferences.HotKeyCombo>(
            get: {
                store.s.hotkeys[action]
                    ?? AppPreferences.defaultHotkeys[action]
                    ?? AppPreferences.HotKeyCombo(keyCode: 0, modifiers: 0)
            },
            set: { newCombo in
                store.s.hotkeys[action] = newCombo   // triggers didSet → save()
                onHotkeysChanged()
            }
        )
    }
}

// MARK: - Shortcut recorder (NSViewRepresentable)

/// A small click-to-record control. Click it, then press a key combo; the next keyDown
/// is captured as `event.keyCode` + Carbon-mapped modifier mask and written into the
/// bound `HotKeyCombo`. Shows a human-readable combo (e.g. ⌥⇧4).
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: AppPreferences.HotKeyCombo

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { keyCode, modifiers in
            combo = AppPreferences.HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
        }
        view.combo = combo
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.combo = combo
    }

    final class RecorderView: NSView {
        var onCapture: ((UInt32, UInt32) -> Void)?
        var combo: AppPreferences.HotKeyCombo = .init(keyCode: 0, modifiers: 0) {
            didSet { needsDisplay = true }
        }
        private var recording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard recording else {
                super.keyDown(with: event)
                return
            }
            // Escape cancels without changing the binding.
            if event.keyCode == UInt16(kVK_Escape) {
                recording = false
                return
            }
            let mods = Self.carbonModifiers(from: event.modifierFlags)
            onCapture?(UInt32(event.keyCode), mods)
            recording = false
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return super.resignFirstResponder()
        }

        override func draw(_ dirtyRect: NSRect) {
            let bg = recording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                               : NSColor.controlBackgroundColor
            bg.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let text = recording ? "Type shortcut…" : Self.displayString(for: combo)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            let pt = NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)
            str.draw(at: pt)
        }

        // MARK: Mapping helpers

        /// AppKit modifier flags → Carbon modifier mask (matches RegisterEventHotKey).
        static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option)  { carbon |= UInt32(optionKey) }
            if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            return carbon
        }

        /// Human-readable combo, e.g. ⌥⇧4. Empty/zero combo shows "Unset".
        static func displayString(for combo: AppPreferences.HotKeyCombo) -> String {
            if combo.keyCode == 0 && combo.modifiers == 0 { return "Unset" }
            var s = ""
            if combo.modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if combo.modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
            if combo.modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
            if combo.modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
            s += KeyCodeNames.string(for: combo.keyCode)
            return s
        }
    }
}

/// Maps Carbon virtual key codes to display strings for the most common keys.
private enum KeyCodeNames {
    static func string(for keyCode: UInt32) -> String {
        if let named = special[Int(keyCode)] { return named }
        if let ansi = ansiMap[Int(keyCode)] { return ansi }
        return "Key \(keyCode)"
    }

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let ansiMap: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}

// MARK: - Shared layout helpers (private to this file)

/// Two-column grid like System Settings: right-aligned labels, leading controls.
private struct SettingsGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            content
        }
        .padding(.top, 6)
    }
}

/// Free-standing row builder used by the tabs (matches RecordingSettingsView's `row`).
@ViewBuilder
private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    GridRow(alignment: .firstTextBaseline) {
        Text(label)
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
        content()
            .gridColumnAlignment(.leading)
    }
}

// MARK: - Raw-value bindings for the enum pickers

private extension Binding where Value == AppPreferences.ImageFormat {
    var rawBinding: Binding<Int> {
        Binding<Int>(get: { wrappedValue.rawValue },
                     set: { wrappedValue = AppPreferences.ImageFormat(rawValue: $0) ?? .png })
    }
}

private extension Binding where Value == AppPreferences.AfterCaptureBehavior {
    var rawBinding: Binding<Int> {
        Binding<Int>(get: { wrappedValue.rawValue },
                     set: { wrappedValue = AppPreferences.AfterCaptureBehavior(rawValue: $0) ?? .showCard })
    }
}

private extension Binding where Value == AppPreferences.CloudProvider {
    var rawBinding: Binding<Int> {
        Binding<Int>(get: { wrappedValue.rawValue },
                     set: { wrappedValue = AppPreferences.CloudProvider(rawValue: $0) ?? .localFolder })
    }
}
