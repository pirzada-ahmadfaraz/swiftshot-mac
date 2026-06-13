import Foundation

/// Best-effort Do Not Disturb / Focus silencing while recording.
///
/// macOS has no public API to toggle Focus modes; we use the same distributed
/// notification that Notification Center listens for. If the OS ignores it on
/// a future release, recording still works — DND just won't activate.
enum DoNotDisturbController {
    private static var didEnable = false

    static func enableIfNeeded(_ shouldEnable: Bool) {
        guard shouldEnable, !didEnable else { return }
        post(name: "com.apple.notification.appCenter.dndStart")
        didEnable = true
    }

    static func restore() {
        guard didEnable else { return }
        post(name: "com.apple.notification.appCenter.dndEnd")
        didEnable = false
    }

    private static func post(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}
