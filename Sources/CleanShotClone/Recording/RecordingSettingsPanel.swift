import AppKit
import SwiftUI

/// Floating settings window for recording preferences — General / Video / GIF tabs.
@MainActor
final class RecordingSettingsPanel {
    static let shared = RecordingSettingsPanel()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: RecordingSettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Recording Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 520, height: 430))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class SettingsStore: ObservableObject {
    @Published var s: RecordingSettings {
        didSet { s.save() }
    }
    init() { s = RecordingSettings.load() }
}

private struct RecordingSettingsView: View {
    @StateObject private var store = SettingsStore()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $tab) {
                Text("General").tag(0)
                Text("Video").tag(1)
                Text("GIF").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .padding(.top, 14)

            Group {
                switch tab {
                case 0: general
                case 1: video
                default: gif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .frame(width: 520, height: 430)
    }

    // MARK: General

    private var general: some View {
        SettingsGrid {
            row("Controls:") {
                Toggle("Show controls while recording", isOn: $store.s.showControlsWhileRecording)
            }
            row("Menu bar:") {
                Toggle("Display recording time", isOn: $store.s.displayTimeInMenuBar)
            }
            row("Retina:") {
                Toggle("Scale Retina videos to 1x", isOn: $store.s.scaleRetinaTo1x)
            }
            row("Notifications:") {
                Toggle("Enable \"Do Not Disturb\" while recording", isOn: $store.s.doNotDisturbWhileRecording)
            }
            row("Cursor:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show cursor", isOn: $store.s.showCursor)
                    Toggle("Highlight clicks", isOn: $store.s.highlightClicks)
                        .onChange(of: store.s.highlightClicks) { _, on in
                            if on { AVPermission.promptAccessibilityIfNeeded() }
                        }
                }
            }
            row("Keyboard:") {
                Toggle("Show Keystrokes", isOn: $store.s.showKeystrokes)
                    .onChange(of: store.s.showKeystrokes) { _, on in
                        if on { AVPermission.promptAccessibilityIfNeeded() }
                    }
            }
            row("Recording area:") {
                Toggle("Remember last selection", isOn: $store.s.rememberLastSelection)
            }
        }
    }

    // MARK: Video

    private var video: some View {
        SettingsGrid {
            row("Frame rate:") {
                Picker("", selection: $store.s.videoFPS) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
                .labelsHidden()
                .frame(width: 130)
            }
            row("Audio:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Record system audio", isOn: $store.s.captureSystemAudio)
                    Toggle("Record microphone", isOn: $store.s.captureMicrophone)
                        .onChange(of: store.s.captureMicrophone) { _, on in
                            if on { AVPermission.requestMicrophone() }
                        }
                }
            }
            row("Webcam:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show webcam overlay", isOn: $store.s.webcamEnabled)
                        .onChange(of: store.s.webcamEnabled) { _, on in
                            if on { AVPermission.requestCamera() }
                        }
                    Picker("Shape:", selection: $store.s.webcamShape.rawBinding) {
                        ForEach(RecordingSettings.WebcamShape.allCases, id: \.rawValue) { shape in
                            Text(shape.label).tag(shape.rawValue)
                        }
                    }
                    .frame(width: 230)
                    Picker("Size:", selection: $store.s.webcamSize.rawBinding) {
                        ForEach(RecordingSettings.WebcamSize.allCases, id: \.rawValue) { size in
                            Text(size.label).tag(size.rawValue)
                        }
                    }
                    .frame(width: 230)
                }
            }
        }
    }

    // MARK: GIF

    private var gif: some View {
        SettingsGrid {
            row("Frame rate:") {
                Picker("", selection: $store.s.gifFPS) {
                    Text("10 FPS").tag(10)
                    Text("12 FPS").tag(12)
                    Text("15 FPS").tag(15)
                    Text("20 FPS").tag(20)
                }
                .labelsHidden()
                .frame(width: 130)
            }
            row("Resolution:") {
                Toggle("Capture at 1x (smaller files)", isOn: $store.s.gifCaptureAt1x)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            content()
                .gridColumnAlignment(.leading)
        }
    }
}

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

private extension Binding where Value == RecordingSettings.WebcamShape {
    var rawBinding: Binding<Int> {
        Binding<Int>(get: { wrappedValue.rawValue },
                     set: { wrappedValue = RecordingSettings.WebcamShape(rawValue: $0) ?? .circle })
    }
}

private extension Binding where Value == RecordingSettings.WebcamSize {
    var rawBinding: Binding<Int> {
        Binding<Int>(get: { wrappedValue.rawValue },
                     set: { wrappedValue = RecordingSettings.WebcamSize(rawValue: $0) ?? .medium })
    }
}
