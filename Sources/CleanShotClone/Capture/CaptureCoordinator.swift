import AppKit
import AVFoundation
import ImageIO
import ScreenCaptureKit

/// Orchestrates the capture flow: trigger → ScreenCaptureKit → show the QuickActions card.
@MainActor
final class CaptureCoordinator {
    private let regionSelection = RegionSelectionController()
    private let windowPicker = WindowPickerController()
    private let scrollingCapture = ScrollingCaptureController()
    private let quickActions = QuickActionsController()
    private var pinnedWindows: [PinnedWindowController] = []
    private var editorWindows: [EditorWindowController] = []

    /// Source-app name captured at trigger time (before the overlay steals focus),
    /// threaded into the capture's history entry.
    private var pendingSourceApp: String?

    /// Per-launch running sequence number for the {seq} filename token.
    private var saveSequence = 0

    func captureArea() {
        pendingSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        regionSelection.start { [weak self] globalRect in
            guard let self, let rect = globalRect else { return }
            Task { await self.performAreaCapture(globalRect: rect) }
        }
    }

    func captureWindow() {
        pendingSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        windowPicker.start { [weak self] windowID in
            guard let self, let id = windowID else { return }
            Task { await self.performWindowCapture(windowID: id) }
        }
    }

    func captureFullScreen() {
        pendingSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        Task { await self.performFullScreenCapture() }
    }

    func captureScrolling() {
        pendingSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        scrollingCapture.start { [weak self] image in
            guard let self, let image else { return }
            self.present(image: image, originRectGlobal: nil)
        }
    }

    func captureText() {
        pendingSourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        regionSelection.start { [weak self] globalRect in
            guard let self, let rect = globalRect else { return }
            Task { await self.performTextCapture(globalRect: rect) }
        }
    }

    // MARK: - Capture implementations

    private func performAreaCapture(globalRect: CGRect) async {
        guard let screen = Coords.screen(containing: globalRect) else { return }
        do {
            let content = try await ScreenshotService.shareableContent()
            guard let scDisplay = Coords.scDisplay(for: screen, in: content) else { return }
            let localRect = Coords.toDisplayLocal(globalRect, on: screen)
            let own = ScreenshotService.ownWindows(in: content)
            let image = try await ScreenshotService.captureRegion(localRect, display: scDisplay, scale: screen.backingScaleFactor, excludingWindows: own)
            present(image: image, originRectGlobal: globalRect)
        } catch {
            Log.error("Area capture failed: \(error)", log: Log.capture)
        }
    }

    private func performTextCapture(globalRect: CGRect) async {
        guard let screen = Coords.screen(containing: globalRect) else { return }
        do {
            let content = try await ScreenshotService.shareableContent()
            guard let scDisplay = Coords.scDisplay(for: screen, in: content) else { return }
            let localRect = Coords.toDisplayLocal(globalRect, on: screen)
            let own = ScreenshotService.ownWindows(in: content)
            let image = try await ScreenshotService.captureRegion(localRect, display: scDisplay, scale: screen.backingScaleFactor, excludingWindows: own)

            let result = await TextRecognizer.recognize(in: image)
            if !result.text.isEmpty {
                copyToClipboard(text: result.text)
                let lines = result.text.split(separator: "\n", omittingEmptySubsequences: true).count
                TextCaptureHUD.show(
                    title: "Text Copied",
                    detail: "\(result.text.count) characters · \(lines) line\(lines == 1 ? "" : "s")",
                    near: globalRect
                )
            } else if let payload = result.qrPayloads.first {
                copyToClipboard(text: payload)
                TextCaptureHUD.show(title: "QR Code Copied", detail: String(payload.prefix(40)) + (payload.count > 40 ? "…" : ""), near: globalRect)
            } else {
                TextCaptureHUD.show(title: "No Text Found", detail: nil, near: globalRect)
            }
        } catch {
            Log.error("Text capture failed: \(error)", log: Log.capture)
        }
    }

    private func copyToClipboard(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func performWindowCapture(windowID: CGWindowID) async {
        do {
            let content = try await ScreenshotService.shareableContent()
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                Log.error("Window \(windowID) not found in shareable content", log: Log.capture)
                return
            }
            let image = try await ScreenshotService.captureWindow(window)
            present(image: image, originRectGlobal: nil)
        } catch {
            Log.error("Window capture failed: \(error)", log: Log.capture)
        }
    }

    private func performFullScreenCapture() async {
        do {
            let content = try await ScreenshotService.shareableContent()
            guard let screen = Coords.screenUnderMouse(),
                  let scDisplay = Coords.scDisplay(for: screen, in: content) else { return }
            let own = ScreenshotService.ownWindows(in: content)
            let image = try await ScreenshotService.captureFullScreen(display: scDisplay, excludingWindows: own)
            present(image: image, originRectGlobal: screen.frame)
        } catch {
            Log.error("Full screen capture failed: \(error)", log: Log.capture)
        }
    }

    // MARK: - Recording results

    /// Show a finished recording (video/GIF) as a quick-action card:
    /// Copy = file to pasteboard, Save = save panel, scissors = trim editor.
    func presentRecording(url: URL, kind: MediaKind) {
        Task { @MainActor in
            guard let thumbnail = await Self.mediaThumbnail(url: url, kind: kind) else {
                Log.error("No thumbnail for recording at \(url.path)", log: Log.recording)
                let alert = NSAlert()
                alert.messageText = "Recording could not be opened"
                alert.informativeText = "The file was saved but could not be previewed. You can still find it at:\n\(url.path)"
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            HistoryStore.shared.add(mediaURL: url, kind: kind, sourceApp: self.pendingSourceApp)
            self.quickActions.presentMedia(
                thumbnail: thumbnail,
                url: url,
                onCopy: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                },
                onSave: { [weak self] in self?.saveMedia(url: url, kind: kind) },
                onTrim: { [weak self] in
                    let trim = TrimWindowController(url: url, kind: kind) { trimmed in
                        self?.presentRecording(url: trimmed, kind: kind)
                    }
                    trim.present()
                }
            )
        }
    }

    private static func mediaThumbnail(url: URL, kind: MediaKind) async -> CGImage? {
        switch kind {
        case .gif:
            return GIFFile.firstFrame(of: url)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1200, height: 0)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            return try? await generator.image(at: .zero).image
        }
    }

    private func saveMedia(url: URL, kind: MediaKind) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = kind == .video ? [.mpeg4Movie] : [.gif]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Recording \(formatter.string(from: Date())).\(kind.fileExtension)"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                DispatchQueue.main.async { Self.presentSaveError(error, to: dest) }
            }
        }
    }

    // MARK: - Presentation

    private func present(image: CGImage, originRectGlobal: CGRect?) {
        HistoryStore.shared.add(image: image, sourceApp: pendingSourceApp, ocrText: nil)

        let prefs = AppPreferences.load()
        switch prefs.afterCaptureBehavior {
        case .copyToClipboard:
            copy(image: image)
            return
        case .openEditor:
            edit(image: image)
            return
        case .showCard:
            if prefs.copyToClipboardAlso { copy(image: image) }
            // fall through to the card below
        }

        quickActions.present(
            image: image,
            originRectGlobal: originRectGlobal,
            onCopy: { [weak self] img in self?.copy(image: img) },
            onSave: { [weak self] img in self?.save(image: img) },
            onPin: { [weak self] img, rect in self?.pin(image: img, atGlobalRect: rect) },
            onEdit: { [weak self] img in self?.edit(image: img) },
            onCloud: { img in CloudService.shared.share(image: img) },
            onRedact: { [weak self] img in self?.redact(image: img, originRectGlobal: originRectGlobal) }
        )
    }

    /// Auto-redact sensitive text (emails, cards, keys, tokens, IPs) and re-present
    /// the result as a fresh card, with a HUD showing how many regions were hidden.
    private func redact(image: CGImage, originRectGlobal: CGRect?) {
        Task { [weak self] in
            let (out, count) = await Redactor.autoRedact(image: image)
            await MainActor.run {
                guard let self else { return }
                self.present(image: out, originRectGlobal: nil)
                let hudRect = originRectGlobal
                    ?? NSScreen.main?.frame
                    ?? CGRect(x: 0, y: 0, width: 800, height: 600)
                TextCaptureHUD.show(
                    title: count == 0 ? "Nothing to Redact" : "Redacted \(count) item\(count == 1 ? "" : "s")",
                    detail: nil,
                    near: hudRect
                )
            }
        }
    }

    /// Public hook so the History window can re-open a stored capture in the editor.
    func openInEditor(_ image: CGImage) { edit(image: image) }

    private func copy(image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
    }

    private func save(image: CGImage) {
        let prefs = AppPreferences.load()
        let panel = NSSavePanel()
        switch prefs.imageFormat {
        case .png:  panel.allowedContentTypes = [.png]
        case .jpg:  panel.allowedContentTypes = [.jpeg]
        case .heic: panel.allowedContentTypes = [.heic]
        }
        panel.nameFieldStringValue = defaultFilename()
        // saveLocationURL resolves the security-scoped bookmark; access it while setting dir.
        let dir = prefs.saveLocationURL
        let scoped = dir.startAccessingSecurityScopedResource()
        panel.directoryURL = dir
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if scoped { dir.stopAccessingSecurityScopedResource() }
            guard response == .OK, let url = panel.url else { return }
            guard let data = Self.encode(image, format: prefs.imageFormat, jpgQuality: prefs.jpgQuality) else { return }
            do { try data.write(to: url) }
            catch { DispatchQueue.main.async { Self.presentSaveError(error, to: url) } }
        }
    }

    /// Encode a CGImage to the chosen format. PNG/JPEG via NSBitmapImageRep; HEIC via CGImageDestination.
    private static func encode(_ image: CGImage, format: AppPreferences.ImageFormat, jpgQuality: Double) -> Data? {
        switch format {
        case .png:
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        case .jpg:
            return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: jpgQuality])
        case .heic:
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpgQuality] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? data as Data : nil
        }
    }

    private func pin(image: CGImage, atGlobalRect rect: CGRect?) {
        let controller = PinnedWindowController(image: image, atGlobalRect: rect)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.pinnedWindows.removeAll { $0 === controller }
        }
        controller.onEdit = { [weak self] in self?.edit(image: image) }
        controller.show()
        pinnedWindows.append(controller)
    }

    private func edit(image: CGImage) {
        let controller = EditorWindowController(image: image)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.editorWindows.removeAll { $0 === controller }
        }
        // On Done, drop the edited image back into the bottom-left card stack.
        controller.onDoneEditing = { [weak self] edited in
            self?.present(image: edited, originRectGlobal: nil)
        }
        controller.show()
        editorWindows.append(controller)
    }

    private static func presentSaveError(_ error: Error, to url: URL) {
        let alert = NSAlert()
        alert.messageText = "Could not save screenshot"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func defaultFilename(appName: String? = nil) -> String {
        let prefs = AppPreferences.load()
        saveSequence += 1
        let base = FilenameTemplate.sanitized(
            FilenameTemplate.render(template: prefs.filenameTemplate,
                                    date: Date(), appName: appName ?? pendingSourceApp, sequence: saveSequence)
        )
        return base + "." + prefs.imageFormat.fileExtension
    }
}
