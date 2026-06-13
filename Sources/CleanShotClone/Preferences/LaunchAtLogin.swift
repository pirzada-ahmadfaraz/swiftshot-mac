import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+) for the "Launch at login"
/// toggle. All calls are guarded with `try?` so a failure (e.g. unsigned/ad-hoc build,
/// or the OS refusing the registration) never throws into the UI — at worst the toggle
/// silently doesn't stick, which `isEnabled` will then reflect.
enum LaunchAtLogin {

    static func set(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.error("LaunchAtLogin.set(\(on)) failed: \(error)", log: Log.general)
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
