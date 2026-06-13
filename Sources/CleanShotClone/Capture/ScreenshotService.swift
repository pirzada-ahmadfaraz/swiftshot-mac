import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Wraps ScreenCaptureKit so callers get back a CGImage without thinking about SCStream lifecycle.
enum ScreenshotService {
    enum CaptureError: Error {
        case displayNotFound
        case captureFailed(Error)
        case noContent
    }

    static func captureFullScreen(display: SCDisplay, excludingWindows: [SCWindow] = []) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let config = baseConfig(width: display.width, height: display.height)
        return try await capture(filter: filter, config: config)
    }

    /// `regionInDisplay` is in points, top-left origin, relative to `display`.
    static func captureRegion(_ regionInDisplay: CGRect, display: SCDisplay, scale: CGFloat, excludingWindows: [SCWindow] = []) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let config = baseConfig(
            width: Int(regionInDisplay.width * scale),
            height: Int(regionInDisplay.height * scale)
        )
        config.sourceRect = regionInDisplay
        return try await capture(filter: filter, config: config)
    }

    static func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Coords.screen(containing: window.frame)?.backingScaleFactor ?? 2.0
        let config = baseConfig(
            width: Int(window.frame.width * scale),
            height: Int(window.frame.height * scale)
        )
        return try await capture(filter: filter, config: config)
    }

    static func shareableContent() async throws -> SCShareableContent {
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Our own app's on-screen windows — passed to `excludingWindows` so the quick-action
    /// cards, pinned windows, editor, and selection overlay never leak into a screenshot.
    static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == myPID }
    }

    // MARK: - Private

    private static func baseConfig(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(width, 1)
        config.height = max(height, 1)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        return config
    }

    private static func capture(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(error)
        }
    }
}
