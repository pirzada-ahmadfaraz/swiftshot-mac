import AppKit

/// Entry point for Record Screen: setup flow (select area / window, options)
/// → live session (chrome, overlays, pause/stop/discard) → result card
/// (Copy / Save / Trim).
@MainActor
final class RecordingController {
    private let setup = RecordingSetupController()
    private var session: RecordingSession?
    private(set) var isRecording = false

    var onStateChange: (() -> Void)?
    /// Elapsed time for the menu bar ("0:42"), nil when idle.
    var onElapsed: ((String?) -> Void)?
    /// Set by AppDelegate so finished recordings land in the card stack.
    weak var capture: CaptureCoordinator?

    init() {
        setup.onOpenSettings = { RecordingSettingsPanel.shared.show() }
    }

    func toggle() {
        if isRecording {
            session?.stopAndSave()
        } else {
            begin()
        }
    }

    func stopIfRecording() {
        session?.stopAndSave()
    }

    private func begin() {
        guard session == nil else { return }
        setup.start { [weak self] result in
            guard let self, let result else { return }
            self.startSession(with: result)
        }
    }

    private func startSession(with result: RecordingSetupResult) {
        let settings = RecordingSettings.load()
        let session = RecordingSession(setup: result, settings: settings)
        session.onElapsed = { [weak self] text in self?.onElapsed?(text) }
        session.onFinished = { [weak self] url, mode, error in
            guard let self else { return }
            self.session = nil
            self.isRecording = false
            self.onStateChange?()
            if let error {
                self.presentError(error, title: "Recording failed")
            } else if let url {
                self.capture?.presentRecording(url: url, kind: mode == .gif ? .gif : .video)
            }
        }
        self.session = session
        self.isRecording = true
        self.onStateChange?()

        Task { @MainActor in
            do {
                try await session.start()
            } catch {
                Log.error("Failed to start recording: \(error)", log: Log.recording)
                self.session = nil
                self.isRecording = false
                self.onStateChange?()
                self.presentError(error, title: "Recording failed to start")
            }
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
