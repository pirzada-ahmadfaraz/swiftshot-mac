import AppKit
import CoreGraphics

/// Facade for "share this to the cloud and copy the link." Picks a provider per
/// `AppPreferences`, runs the upload off the main actor's critical path, copies the
/// resulting link to the pasteboard, and confirms with a toast. Never crashes —
/// every failure is surfaced via a toast or NSAlert.
///
/// Entry points are deliberately fire-and-forget (`func share(...)`, no `await`):
/// the QuickActions card's `onCloud` closure just calls these.
@MainActor
final class CloudService {
    static let shared = CloudService()

    /// Set by the integrator (AppDelegate) so the "not configured" alert can open
    /// Preferences without this file depending on the prefs window controller.
    var onOpenPreferences: (() -> Void)?

    /// Default destination when the user hasn't picked a synced folder.
    private static var defaultPublicFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Public", isDirectory: true)
            .appendingPathComponent("SwiftShot", isDirectory: true)
    }

    private init() {}

    // MARK: - Public API

    /// Share a still image: writes a temp PNG, then shares the file.
    func share(image: CGImage) {
        guard let url = writeTemporaryPNG(image) else {
            showError(message: "Couldn't prepare the image for sharing.")
            return
        }
        share(fileURL: url, cleanUpTempFile: true)
    }

    /// Share an existing file on disk (recordings, GIFs, …).
    func share(fileURL: URL) {
        share(fileURL: fileURL, cleanUpTempFile: false)
    }

    // MARK: - Core

    private func share(fileURL: URL, cleanUpTempFile: Bool) {
        let prefs = AppPreferences.load()

        // Resolve the provider up front so "not configured" is synchronous.
        let provider: CloudUploader
        switch prefs.cloudProvider {
        case .localFolder:
            let folder = prefs.cloudFolderURL ?? Self.defaultPublicFolder
            provider = LocalLinkProvider(folderURL: folder, publicBaseURL: prefs.cloudPublicBaseURL)

        case .httpEndpoint:
            let endpoint = prefs.cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty, let url = URL(string: endpoint), url.scheme != nil else {
                showNotConfigured()
                if cleanUpTempFile { try? FileManager.default.removeItem(at: fileURL) }
                return
            }
            let token = prefs.cloudToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = prefs.cloudResponseURLKey.isEmpty ? "url" : prefs.cloudResponseURLKey
            provider = HTTPEndpointProvider(endpoint: url, token: token.isEmpty ? nil : token, responseURLKey: key)
        }

        CloudToast.showPersistent(title: "Sharing…", symbol: "arrow.up.circle")

        Task { @MainActor in
            defer { if cleanUpTempFile { try? FileManager.default.removeItem(at: fileURL) } }
            do {
                let link = try await provider.upload(fileURL: fileURL)
                copyToPasteboard(link)
                CloudToast.show(title: "Link Copied", detail: shortLink(link), symbol: "link")
                Log.info("Cloud: shared \(fileURL.lastPathComponent) -> \(link.absoluteString)", log: Log.general)
            } catch let error as CloudError {
                handle(error)
            } catch {
                Log.error("Cloud: unexpected upload error: \(error)", log: Log.general)
                showError(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Result handling

    private func copyToPasteboard(_ link: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link.absoluteString, forType: .string)
    }

    private func handle(_ error: CloudError) {
        CloudToast.dismiss()
        switch error {
        case .notConfigured:
            showNotConfigured()
        default:
            Log.error("Cloud: \(error.localizedDescription)", log: Log.general)
            showError(message: error.localizedDescription)
        }
    }

    private func showError(message: String) {
        CloudToast.dismiss()
        let alert = NSAlert()
        alert.messageText = "Sharing failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showNotConfigured() {
        CloudToast.dismiss()
        let alert = NSAlert()
        alert.messageText = "Cloud sharing isn't set up"
        alert.informativeText = """
        Choose a sharing destination in Preferences. You can copy screenshots into a \
        synced or public folder (Dropbox, iCloud Drive, a web root) and optionally map \
        it to a public link, or point SwiftShot at your own upload endpoint.
        """
        alert.alertStyle = .informational
        let openButton = alert.addButton(withTitle: "Open Preferences…")
        alert.addButton(withTitle: "Cancel")
        openButton.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onOpenPreferences?()
        }
    }

    // MARK: - Helpers

    /// Writes a PNG of `image` into the temp dir; returns nil on failure.
    private func writeTemporaryPNG(_ image: CGImage) -> URL? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(formatter.string(from: Date())).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            Log.error("Cloud: could not write temp PNG: \(error)", log: Log.general)
            return nil
        }
    }

    /// A compact form of the link for the confirmation toast's detail line.
    private func shortLink(_ link: URL) -> String {
        if link.isFileURL {
            return link.lastPathComponent
        }
        let host = link.host ?? ""
        let path = link.path
        let combined = host + path
        return combined.count > 44 ? String(combined.prefix(44)) + "…" : combined
    }
}
