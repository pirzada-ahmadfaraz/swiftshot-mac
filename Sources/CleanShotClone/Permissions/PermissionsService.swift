import AppKit
import CoreGraphics

enum PermissionsService {
    static func ensureScreenRecordingPermission() {
        // CGPreflightScreenCaptureAccess returns true if access has been granted.
        if CGPreflightScreenCaptureAccess() { return }

        // This will prompt the user once, after which the app appears under
        // System Settings → Privacy & Security → Screen Recording.
        _ = CGRequestScreenCaptureAccess()

        // If we still don't have it, surface a dialog pointing the user to settings.
        if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.async { showSettingsAlert() }
        }
    }

    private static func showSettingsAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = "SwiftShot needs Screen Recording permission to capture screenshots and record. Open System Settings → Privacy & Security → Screen Recording and enable SwiftShot, then relaunch the app."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
