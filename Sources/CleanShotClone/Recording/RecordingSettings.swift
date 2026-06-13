import Foundation
import CoreGraphics

/// All recording preferences, persisted to UserDefaults. Single source of truth
/// for the setup panel toggles AND the settings window — both read/write here.
struct RecordingSettings {

    enum WebcamShape: Int, CaseIterable {
        case roundedRectangle = 0
        case circle = 1

        var label: String {
            switch self {
            case .roundedRectangle: return "Rounded Rectangle"
            case .circle: return "Circle"
            }
        }
    }

    enum WebcamSize: Int, CaseIterable {
        case small = 0, medium = 1, large = 2

        var label: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }

        /// Longest edge of the webcam bubble in points.
        var points: CGFloat {
            switch self {
            case .small: return 140
            case .medium: return 200
            case .large: return 280
            }
        }
    }

    // General
    var showControlsWhileRecording = true
    var displayTimeInMenuBar = false
    var scaleRetinaTo1x = false
    var doNotDisturbWhileRecording = true
    var showCursor = true
    var highlightClicks = false
    var showKeystrokes = false
    var rememberLastSelection = false

    // Video
    var videoFPS = 60
    var captureSystemAudio = false
    var captureMicrophone = false

    // GIF
    var gifFPS = 12
    var gifCaptureAt1x = true

    // Webcam
    var webcamEnabled = false
    var webcamShape: WebcamShape = .circle
    var webcamSize: WebcamSize = .medium

    // Remembered selection (AppKit global coords), only honored when
    // `rememberLastSelection` is on.
    var lastSelection: CGRect?

    // MARK: - Persistence

    private static let key = "RecordingSettings"

    static func load() -> RecordingSettings {
        var s = RecordingSettings()
        guard let d = UserDefaults.standard.dictionary(forKey: key) else { return s }
        s.showControlsWhileRecording = d["showControls"] as? Bool ?? s.showControlsWhileRecording
        s.displayTimeInMenuBar = d["menuBarTime"] as? Bool ?? s.displayTimeInMenuBar
        s.scaleRetinaTo1x = d["retina1x"] as? Bool ?? s.scaleRetinaTo1x
        s.doNotDisturbWhileRecording = d["dnd"] as? Bool ?? s.doNotDisturbWhileRecording
        s.showCursor = d["showCursor"] as? Bool ?? s.showCursor
        s.highlightClicks = d["highlightClicks"] as? Bool ?? s.highlightClicks
        s.showKeystrokes = d["showKeystrokes"] as? Bool ?? s.showKeystrokes
        s.rememberLastSelection = d["rememberSelection"] as? Bool ?? s.rememberLastSelection
        s.videoFPS = d["videoFPS"] as? Int ?? s.videoFPS
        s.captureSystemAudio = d["systemAudio"] as? Bool ?? s.captureSystemAudio
        s.captureMicrophone = d["microphone"] as? Bool ?? s.captureMicrophone
        s.gifFPS = d["gifFPS"] as? Int ?? s.gifFPS
        s.gifCaptureAt1x = d["gif1x"] as? Bool ?? s.gifCaptureAt1x
        s.webcamEnabled = d["webcamEnabled"] as? Bool ?? s.webcamEnabled
        s.webcamShape = (d["webcamShape"] as? Int).flatMap(WebcamShape.init) ?? s.webcamShape
        s.webcamSize = (d["webcamSize"] as? Int).flatMap(WebcamSize.init) ?? s.webcamSize
        if let r = d["lastSelection"] as? [Double], r.count == 4 {
            s.lastSelection = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }
        return s
    }

    func save() {
        var d: [String: Any] = [
            "showControls": showControlsWhileRecording,
            "menuBarTime": displayTimeInMenuBar,
            "retina1x": scaleRetinaTo1x,
            "dnd": doNotDisturbWhileRecording,
            "showCursor": showCursor,
            "highlightClicks": highlightClicks,
            "showKeystrokes": showKeystrokes,
            "rememberSelection": rememberLastSelection,
            "videoFPS": videoFPS,
            "systemAudio": captureSystemAudio,
            "microphone": captureMicrophone,
            "gifFPS": gifFPS,
            "gif1x": gifCaptureAt1x,
            "webcamEnabled": webcamEnabled,
            "webcamShape": webcamShape.rawValue,
            "webcamSize": webcamSize.rawValue,
        ]
        if let r = lastSelection {
            d["lastSelection"] = [r.origin.x, r.origin.y, r.width, r.height].map(Double.init)
        }
        UserDefaults.standard.set(d, forKey: Self.key)
    }
}
