import AppKit
import ScreenCaptureKit

/// Coordinate-space conversions between AppKit (bottom-left, multi-screen), Quartz/SCK (top-left per-display), and pixels.
enum Coords {
    /// Primary display — used as the Y-flip anchor for AppKit ↔ Quartz conversions.
    static var primaryScreen: NSScreen? { NSScreen.screens.first }

    /// The NSScreen whose frame contains the mouse cursor.
    static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Convert an AppKit global point (bottom-left origin) to Quartz/CG screen space (top-left origin).
    static func appKitGlobalToQuartz(_ point: CGPoint) -> CGPoint {
        guard let primary = primaryScreen else { return point }
        return CGPoint(x: point.x, y: primary.frame.height - point.y)
    }

    /// Convert a Quartz/CG window bounds rect to AppKit global desktop coordinates.
    static func quartzRectToAppKit(_ rect: CGRect) -> CGRect {
        guard let primary = primaryScreen else { return rect }
        return CGRect(
            x: rect.origin.x,
            y: primary.frame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
    /// Convert a rect in AppKit global desktop space to (display-local, top-left origin, points).
    /// `screen` is the NSScreen the rect lies on.
    static func toDisplayLocal(_ rectAppKit: CGRect, on screen: NSScreen) -> CGRect {
        let local = CGRect(
            x: rectAppKit.origin.x - screen.frame.origin.x,
            y: rectAppKit.origin.y - screen.frame.origin.y,
            width: rectAppKit.width,
            height: rectAppKit.height
        )
        // Flip y: AppKit local has origin at bottom of this screen; SCK wants top-left.
        let flippedY = screen.frame.height - local.origin.y - local.height
        return CGRect(x: local.origin.x, y: flippedY, width: local.width, height: local.height)
    }

    /// Find the NSScreen whose frame contains the largest portion of `rectAppKit`.
    static func screen(containing rectAppKit: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        return screens.max(by: { a, b in
            a.frame.intersection(rectAppKit).area < b.frame.intersection(rectAppKit).area
        }) ?? screens.first
    }

    /// Match an NSScreen to its corresponding SCDisplay by displayID.
    static func scDisplay(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let displayID = screen.displayID else { return nil }
        return content.displays.first(where: { $0.displayID == displayID })
    }
}

extension CGRect {
    fileprivate var area: CGFloat { width * height }
}

extension NSScreen {
    /// The CGDirectDisplayID for this screen (as exposed via deviceDescription).
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID
    }
}
