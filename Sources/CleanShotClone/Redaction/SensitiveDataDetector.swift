import CoreGraphics
import Foundation

/// Pure, string-based detection of personally/secret-sensitive text.
///
/// Everything here is UI-free and works on plain `String`s so the matching logic
/// can be exercised from a throwaway `/tmp` harness with synthetic inputs. The
/// only non-`Foundation` dependency is `CGRect` (via `TextRecognizer.Fragment`),
/// used solely to map matching fragments back to the rectangles a redactor paints
/// over.
///
/// Detection deliberately favours precision over recall: ordinary prose (short
/// numbers, plain words) must not be flagged, while real emails, Luhn-valid card
/// numbers, API keys, tokens and IP addresses are caught.
enum SensitiveDataDetector {

    enum SensitiveKind {
        case email
        case creditCard
        case phone
        case ipv4
        case jwt
        case awsAccessKey
        case bearerToken
        case secretHex
    }

    // MARK: - Public detection

    /// All sensitive spans found in `text`, each tagged with what it looks like.
    /// A single string can contain several matches of different kinds.
    static func sensitiveRanges(in text: String) -> [(kind: SensitiveKind, range: Range<String.Index>)] {
        var results: [(kind: SensitiveKind, range: Range<String.Index>)] = []

        for kind in orderedKinds {
            for range in matches(for: kind, in: text) {
                results.append((kind, range))
            }
        }
        return results
    }

    /// Convenience predicate: does this text contain anything sensitive at all?
    static func containsSensitive(_ text: String) -> Bool {
        !sensitiveRanges(in: text).isEmpty
    }

    /// The pixel rects (one per fragment) of every OCR fragment whose text holds
    /// at least one sensitive span. These are the boxes a redactor paints over.
    static func redactionRects(fragments: [TextRecognizer.Fragment]) -> [CGRect] {
        fragments.compactMap { containsSensitive($0.text) ? $0.rect : nil }
    }

    // MARK: - Luhn

    /// Standard Luhn checksum over the digits in `digits` (non-digits ignored).
    /// Returns false for empty / single-digit input.
    static func luhn(_ digits: String) -> Bool {
        let nums = digits.compactMap { $0.wholeNumberValue }
        guard nums.count >= 2 else { return false }

        var sum = 0
        // Walk right-to-left, doubling every second digit.
        for (offset, digit) in nums.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    // MARK: - Matching

    /// Evaluation order: highly specific structured secrets first, generic hex
    /// last (so e.g. a JWT or AWS key isn't merely caught as "long hex").
    private static let orderedKinds: [SensitiveKind] = [
        .email, .jwt, .awsAccessKey, .bearerToken, .creditCard, .ipv4, .phone, .secretHex,
    ]

    private static func matches(for kind: SensitiveKind, in text: String) -> [Range<String.Index>] {
        switch kind {
        case .email:
            return rawMatches(pattern: emailPattern, in: text)
        case .jwt:
            return rawMatches(pattern: jwtPattern, in: text)
        case .awsAccessKey:
            return rawMatches(pattern: awsKeyPattern, in: text)
        case .bearerToken:
            return rawMatches(pattern: bearerPattern, in: text, options: [.caseInsensitive])
        case .ipv4:
            return rawMatches(pattern: ipv4Pattern, in: text).filter { isValidIPv4(String(text[$0])) }
        case .secretHex:
            return rawMatches(pattern: secretHexPattern, in: text)
        case .creditCard:
            // Candidate runs of 13–19 digits possibly separated by spaces/dashes;
            // only those whose digits pass Luhn are real card numbers.
            return rawMatches(pattern: cardPattern, in: text).filter {
                let digits = String(text[$0]).filter(\.isNumber)
                return (13...19).contains(digits.count) && luhn(digits)
            }
        case .phone:
            // A phone is a longish run of dialling characters with enough digits
            // to be a real number, and not a date/version-looking token.
            return rawMatches(pattern: phonePattern, in: text).filter { isLikelyPhone(String(text[$0])) }
        }
    }

    // MARK: - Patterns

    // Emails: standard local@domain.tld with a 2+ letter TLD.
    private static let emailPattern =
        #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#

    // JWT: three base64url segments separated by dots, beginning with the
    // ubiquitous "eyJ" header prefix.
    private static let jwtPattern =
        #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#

    // AWS access key id.
    private static let awsKeyPattern =
        #"AKIA[0-9A-Z]{16}"#

    // "Bearer <token>" / "bearer <token>" (Authorization headers, logs).
    private static let bearerPattern =
        #"bearer\s+[A-Za-z0-9._\-]+"#

    // Candidate card: 13–19 digits in groups separated by single spaces/dashes.
    private static let cardPattern =
        #"\b(?:\d[ \-]?){13,19}\b"#

    // Dotted quad shape; per-octet 0–255 validation happens afterwards. The
    // lookarounds reject quads that are merely a prefix/suffix of a longer
    // dotted-numeric run (e.g. version strings like "1.2.3.4.5"), which are
    // ordinary prose, not IP addresses.
    private static let ipv4Pattern =
        #"(?<![\d.])\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![\d.])"#

    // Phone-ish: optional +, then digits and the usual separators, long enough
    // to be a real number. Length/digit-count sanity applied afterwards.
    private static let phonePattern =
        #"\+?\d[\d\-\s().]{7,}\d"#

    // Generic secret: a run of 32+ hex characters (API keys, hashes, tokens).
    private static let secretHexPattern =
        #"\b[0-9a-fA-F]{32,}\b"#

    // MARK: - Regex helpers

    private static func rawMatches(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: full).compactMap {
            Range($0.range, in: text)
        }
    }

    // MARK: - Validators

    /// Every octet of a dotted quad must be 0–255 (and not zero-padded nonsense
    /// beyond three digits, which the regex already bounds).
    private static func isValidIPv4(_ candidate: String) -> Bool {
        let octets = candidate.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return true
        }
    }

    /// A phone match should carry enough digits to be a genuine number (7–15,
    /// the E.164 range) and not be a decimal/version string masquerading as one.
    private static func isLikelyPhone(_ candidate: String) -> Bool {
        let digitCount = candidate.filter(\.isNumber).count
        guard (7...15).contains(digitCount) else { return false }
        // Reject things that are mostly dots (IPs/versions) — phones use spaces,
        // dashes and parens, not dot separators between every group.
        let dotCount = candidate.filter { $0 == "." }.count
        if dotCount >= 2 { return false }
        return true
    }
}
