import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var hotkeys: HotKeyManager!
    private(set) var capture: CaptureCoordinator!
    private(set) var recording: RecordingController!
    private var hotkeyHandlers: [HotKeyAction: () -> Void] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another copy is already running, hand off to it and quit.
        // Multiple instances each add a status item and compete for the (full) menu bar.
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ahmadfaraz.cleanshotclone")
            .filter { $0.processIdentifier != mine }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        PermissionsService.ensureScreenRecordingPermission()

        capture = CaptureCoordinator()
        recording = RecordingController()
        menuBar = MenuBarController(
            onCaptureArea: { [weak self] in self?.capture.captureArea() },
            onCaptureWindow: { [weak self] in self?.capture.captureWindow() },
            onCaptureFullScreen: { [weak self] in self?.capture.captureFullScreen() },
            onCaptureScrolling: { [weak self] in self?.capture.captureScrolling() },
            onCaptureText: { [weak self] in self?.capture.captureText() },
            onToggleRecording: { [weak self] in self?.recording.toggle() },
            onOpenHistory: { HistoryWindowController.shared.show() },
            onOpenPreferences: { PreferencesWindowController.shared.show() },
            isRecording: { [weak self] in self?.recording.isRecording ?? false }
        )
        recording.onStateChange = { [weak self] in self?.menuBar.refreshState() }
        recording.onElapsed = { [weak self] text in self?.menuBar.setRecordingElapsed(text) }
        recording.capture = capture

        // History re-opens stored captures in the editor via the coordinator.
        HistoryWindowController.shared.onOpenInEditor = { [weak self] image in
            self?.capture.openInEditor(image)
        }
        // Cloud's "not configured" alert can jump to Preferences.
        CloudService.shared.onOpenPreferences = { PreferencesWindowController.shared.show() }

        hotkeys = HotKeyManager()
        hotkeyHandlers = [
            .captureArea:       { [weak self] in self?.capture.captureArea() },
            .captureWindow:     { [weak self] in self?.capture.captureWindow() },
            .captureFullScreen: { [weak self] in self?.capture.captureFullScreen() },
            .captureScrolling:  { [weak self] in self?.capture.captureScrolling() },
            .captureText:       { [weak self] in self?.capture.captureText() },
            .toggleRecording:   { [weak self] in self?.recording.toggle() },
        ]
        let prefs = AppPreferences.load()
        hotkeys.reload(from: prefs, handlers: hotkeyHandlers)
        LaunchAtLogin.set(prefs.launchAtLogin)   // reconcile OS state with the pref at launch

        PreferencesWindowController.shared.onHotkeysChanged = { [weak self] in
            guard let self else { return }
            self.hotkeys.reload(from: AppPreferences.load(), handlers: self.hotkeyHandlers)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recording?.stopIfRecording()
    }
}
