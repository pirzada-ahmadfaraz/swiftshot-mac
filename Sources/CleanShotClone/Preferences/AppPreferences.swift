import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// The ONE app-wide settings store. Persisted to UserDefaults under the key
/// "AppPreferences", mirroring the `RecordingSettings` load()/save() pattern exactly.
///
/// This struct owns settings for ALL features (general/output, hotkeys, AND the
/// cloud-sharing fields), so there is a single source of truth. The Preferences UI
/// binds to it; `CaptureCoordinator`, `HotKeyManager`, `AppDelegate`, and the cloud
/// service all read it via `AppPreferences.load()`.
///
/// Deliberately AppKit-free (Foundation + CoreGraphics + Carbon only) so the pure
/// round-trip can be exercised in a throwaway harness.
struct AppPreferences {

    // MARK: - Nested types

    enum ImageFormat: Int, CaseIterable {
        case png = 0
        case jpg = 1
        case heic = 2

        var label: String {
            switch self {
            case .png:  return "PNG"
            case .jpg:  return "JPEG"
            case .heic: return "HEIC"
            }
        }

        /// File extension WITHOUT the leading dot.
        var fileExtension: String {
            switch self {
            case .png:  return "png"
            case .jpg:  return "jpg"
            case .heic: return "heic"
            }
        }

        /// UTType identifier string (avoids importing UniformTypeIdentifiers here so the
        /// struct stays link-light; callers can build `UTType(utTypeIdentifier)`).
        var utTypeIdentifier: String {
            switch self {
            case .png:  return "public.png"
            case .jpg:  return "public.jpeg"
            case .heic: return "public.heic"
            }
        }
    }

    enum AfterCaptureBehavior: Int, CaseIterable {
        case showCard = 0
        case copyToClipboard = 1
        case openEditor = 2

        var label: String {
            switch self {
            case .showCard:        return "Show Quick Action Card"
            case .copyToClipboard: return "Copy to Clipboard"
            case .openEditor:      return "Open in Editor"
            }
        }
    }

    enum CloudProvider: Int, CaseIterable {
        case localFolder = 0
        case httpEndpoint = 1

        var label: String {
            switch self {
            case .localFolder:  return "Local Folder"
            case .httpEndpoint: return "HTTP Endpoint"
            }
        }
    }

    /// A keyboard shortcut: Carbon virtual key code + Carbon modifier mask
    /// (e.g. `UInt32(optionKey | shiftKey)`), matching what `RegisterEventHotKey` wants.
    struct HotKeyCombo: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    // MARK: - General / Output fields

    /// Security-scoped bookmark to the user's chosen save folder (nil → Desktop).
    var saveLocationBookmark: Data?
    var imageFormat: ImageFormat = .png
    var jpgQuality: Double = 0.9
    var filenameTemplate: String = "Screenshot {datetime}"
    var afterCaptureBehavior: AfterCaptureBehavior = .showCard
    var copyToClipboardAlso = false
    var playSounds = true
    var launchAtLogin = false

    /// Per-action keyboard shortcuts. Defaults to today's hardcoded values so the
    /// out-of-the-box behavior is unchanged.
    var hotkeys: [HotKeyAction: HotKeyCombo] = AppPreferences.defaultHotkeys

    // MARK: - Cloud / Sharing fields (owned here on cloud's behalf; names are frozen)

    var cloudProvider: CloudProvider = .httpEndpoint
    /// Security-scoped bookmark for the local "public/synced" folder.
    var cloudFolderBookmark: Data?
    var cloudPublicBaseURL: String = ""
    /// Project default: the swiftshot.online Cloudflare Worker upload endpoint.
    var cloudEndpoint: String = "https://up.swiftshot.online/"
    /// The upload token is a SECRET — deliberately NOT committed here. It lives in
    /// the user's local prefs (set via Preferences → Cloud). Without it the Worker
    /// returns 401. Rotate it in the Worker's UPLOAD_TOKEN secret if it leaks.
    var cloudToken: String = ""
    var cloudResponseURLKey: String = "url"

    // MARK: - Defaults

    /// EXACTLY the current hardcoded hotkey defaults (contract §4): all use ⌥⇧.
    static let defaultHotkeys: [HotKeyAction: HotKeyCombo] = {
        let mods = UInt32(optionKey | shiftKey)
        return [
            .captureArea:       HotKeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: mods),
            .captureWindow:     HotKeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: mods),
            .captureFullScreen: HotKeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: mods),
            .captureScrolling:  HotKeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: mods),
            .toggleRecording:   HotKeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: mods),
            .captureText:       HotKeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: mods),
        ]
    }()

    // MARK: - Computed resolved URLs

    /// Resolved save folder. Falls back to ~/Desktop when no bookmark is set or it
    /// cannot be resolved. NOTE: the caller is responsible for the
    /// startAccessingSecurityScopedResource / stop dance when writing.
    var saveLocationURL: URL {
        if let url = Self.resolveBookmark(saveLocationBookmark) {
            return url
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    /// Resolved cloud folder, or nil when no bookmark is set. (cloud falls back to
    /// ~/Public/SwiftShot itself when this is nil.)
    var cloudFolderURL: URL? {
        Self.resolveBookmark(cloudFolderBookmark)
    }

    /// Resolve a security-scoped bookmark to a URL (ignoring staleness — we just want a
    /// usable path; re-bookmarking on staleness is a UI concern).
    private static func resolveBookmark(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    // MARK: - Persistence

    private static let key = "AppPreferences"

    static func load() -> AppPreferences {
        var s = AppPreferences()
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return s }

        s.saveLocationBookmark = d["saveLocationBookmark"] as? Data
        s.imageFormat = (d["imageFormat"] as? Int).flatMap(ImageFormat.init) ?? s.imageFormat
        s.jpgQuality = d["jpgQuality"] as? Double ?? s.jpgQuality
        s.filenameTemplate = d["filenameTemplate"] as? String ?? s.filenameTemplate
        s.afterCaptureBehavior = (d["afterCaptureBehavior"] as? Int).flatMap(AfterCaptureBehavior.init) ?? s.afterCaptureBehavior
        s.copyToClipboardAlso = d["copyToClipboardAlso"] as? Bool ?? s.copyToClipboardAlso
        s.playSounds = d["playSounds"] as? Bool ?? s.playSounds
        s.launchAtLogin = d["launchAtLogin"] as? Bool ?? s.launchAtLogin

        if let raw = d["hotkeys"] as? [String: [String: UInt32]] {
            s.hotkeys = Self.decodeHotkeys(raw)
        }

        s.cloudProvider = (d["cloudProvider"] as? Int).flatMap(CloudProvider.init) ?? s.cloudProvider
        s.cloudFolderBookmark = d["cloudFolderBookmark"] as? Data
        s.cloudPublicBaseURL = d["cloudPublicBaseURL"] as? String ?? s.cloudPublicBaseURL
        s.cloudEndpoint = d["cloudEndpoint"] as? String ?? s.cloudEndpoint
        s.cloudToken = d["cloudToken"] as? String ?? s.cloudToken
        s.cloudResponseURLKey = d["cloudResponseURLKey"] as? String ?? s.cloudResponseURLKey

        return s
    }

    func save() {
        var d: [String: Any] = [
            "imageFormat": imageFormat.rawValue,
            "jpgQuality": jpgQuality,
            "filenameTemplate": filenameTemplate,
            "afterCaptureBehavior": afterCaptureBehavior.rawValue,
            "copyToClipboardAlso": copyToClipboardAlso,
            "playSounds": playSounds,
            "launchAtLogin": launchAtLogin,
            "hotkeys": Self.encodeHotkeys(hotkeys),
            "cloudProvider": cloudProvider.rawValue,
            "cloudPublicBaseURL": cloudPublicBaseURL,
            "cloudEndpoint": cloudEndpoint,
            "cloudToken": cloudToken,
            "cloudResponseURLKey": cloudResponseURLKey,
        ]
        if let saveLocationBookmark { d["saveLocationBookmark"] = saveLocationBookmark }
        if let cloudFolderBookmark { d["cloudFolderBookmark"] = cloudFolderBookmark }
        UserDefaults.standard.set(d, forKey: Self.key)
    }

    // MARK: - Hotkey (de)serialization

    /// Persist as `[String(action.rawValue): ["keyCode": ..., "modifiers": ...]]`.
    static func encodeHotkeys(_ map: [HotKeyAction: HotKeyCombo]) -> [String: [String: UInt32]] {
        var out: [String: [String: UInt32]] = [:]
        for (action, combo) in map {
            out[String(action.rawValue)] = ["keyCode": combo.keyCode, "modifiers": combo.modifiers]
        }
        return out
    }

    /// Inverse of `encodeHotkeys`. Starts from the defaults so any action missing from
    /// the stored dictionary keeps its default combo (forward-compatible if we add an
    /// action later).
    static func decodeHotkeys(_ raw: [String: [String: UInt32]]) -> [HotKeyAction: HotKeyCombo] {
        var map = defaultHotkeys
        for (key, sub) in raw {
            guard let rawValue = UInt32(key),
                  let action = HotKeyAction(rawValue: rawValue),
                  let keyCode = sub["keyCode"],
                  let modifiers = sub["modifiers"] else { continue }
            map[action] = HotKeyCombo(keyCode: keyCode, modifiers: modifiers)
        }
        return map
    }
}
