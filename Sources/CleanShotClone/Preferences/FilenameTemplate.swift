import Foundation

/// Pure, UI-free filename templating. Used by `CaptureCoordinator.save(image:)` to turn
/// `AppPreferences.filenameTemplate` into a concrete filename (without extension).
///
/// Supported tokens (case-sensitive, wrapped in braces):
///   {date}     → yyyy-MM-dd
///   {time}     → HH.mm.ss            (colons are illegal in HFS+ filenames)
///   {datetime} → yyyy-MM-dd 'at' HH.mm.ss
///   {app}      → the source app name, or "" when unknown
///   {seq}      → the running sequence number
///   {uuid}     → a short (8-char) UUID prefix
///
/// Unknown tokens are passed through literally (e.g. "{foo}" stays "{foo}"), so a user
/// typo never silently eats characters.
enum FilenameTemplate {

    static func render(template: String, date: Date, appName: String?, sequence: Int) -> String {
        let cal = Locale(identifier: "en_US_POSIX")

        func formatted(_ format: String) -> String {
            let f = DateFormatter()
            f.locale = cal
            f.dateFormat = format
            return f.string(from: date)
        }

        let replacements: [String: String] = [
            "{date}":     formatted("yyyy-MM-dd"),
            "{time}":     formatted("HH.mm.ss"),
            "{datetime}": formatted("yyyy-MM-dd 'at' HH.mm.ss"),
            "{app}":      appName ?? "",
            "{seq}":      String(sequence),
            "{uuid}":     String(UUID().uuidString.prefix(8)),
        ]

        var result = template
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    /// Strips characters that are illegal or awkward in macOS filenames, collapsing
    /// runs of whitespace. Safe to call on the output of `render(...)`. Never returns
    /// an empty string (falls back to "Screenshot").
    static func sanitized(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Screenshot" : cleaned
    }
}
