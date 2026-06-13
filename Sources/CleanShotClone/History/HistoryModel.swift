import Foundation

/// The on-disk index model for the capture library.
///
/// Deliberately AppKit-free (only Foundation) so the pure pieces — the Codable
/// round-trip and `HistoryStore.filter(items:query:)` — can be exercised by a
/// throwaway harness without linking the whole app. `HistoryStore` (which does
/// touch AppKit/CoreGraphics) lives in a separate file.

/// One entry in the capture library.
struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let type: ItemType
    /// Path of the asset, RELATIVE to the Library directory (e.g. "<id>.png").
    let assetPath: String
    /// Path of the thumbnail PNG, RELATIVE to the Library directory.
    let thumbnailPath: String
    let createdAt: Date
    let sourceApp: String?
    let ocrText: String?
}

/// What kind of capture an item is. String-raw so the JSON is human-readable.
enum ItemType: String, Codable {
    case image, video, gif
}

extension HistoryItem {
    /// The asset filename only (last path component), used by search + UI.
    var filename: String {
        (assetPath as NSString).lastPathComponent
    }
}

// MARK: - Pure search filter (harness-tested)

extension HistoryStore {

    /// Date format used both for the on-screen subtitle and for date-substring
    /// search, so typing e.g. "2026-06" or "Jun" narrows by capture time.
    private static let searchDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm MMM d"
        return f
    }()

    /// Case-insensitive substring match across the asset filename, OCR text,
    /// source app, and a formatted capture-date string. An empty/whitespace
    /// query returns every item unchanged. Pure — no AppKit, no I/O.
    static func filter(items: [HistoryItem], query: String) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let needle = trimmed.lowercased()
        return items.filter { item in
            var haystack = item.filename.lowercased()
            if let ocr = item.ocrText { haystack += "\n" + ocr.lowercased() }
            if let app = item.sourceApp { haystack += "\n" + app.lowercased() }
            haystack += "\n" + searchDateFormatter.string(from: item.createdAt).lowercased()
            return haystack.contains(needle)
        }
    }
}
