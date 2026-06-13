import CoreGraphics
import Foundation
import Vision

/// On-device OCR that preserves the visual structure of what was captured.
///
/// Vision returns flat text fragments with bounding boxes; everything that makes
/// the copied text *read* like the original is reconstructed here:
/// - fragments are grouped into visual lines by vertical overlap
/// - paragraph breaks are inferred from the gap statistics of the capture itself
///   (no absolute pixel thresholds — adapts to any font size / screen scale)
/// - headings (taller than the body text) get separating blank lines
/// - indentation is rebuilt from horizontal offsets in character-width units, so
///   nested bullets and numbered steps keep their hierarchy
/// - large in-line gaps become column spacing instead of collapsing to one space
/// - misread bullet glyphs are normalized to "•"
///
/// A QR/barcode pass runs alongside; if the selection contains no readable text
/// but holds a code, the payload is used instead.
enum TextRecognizer {

    struct Fragment {
        let text: String
        /// Pixel coordinates, top-left origin.
        let rect: CGRect

        init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    struct CaptureResult {
        let text: String
        let qrPayloads: [String]
        var isEmpty: Bool { text.isEmpty && qrPayloads.isEmpty }
    }

    // MARK: - Recognition

    static func recognize(in image: CGImage) async -> CaptureResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: performRecognition(in: image))
            }
        }
    }

    /// Per-fragment recognition for redaction: every readable text fragment with
    /// its pixel rect (top-left origin), no layout reconstruction or QR pass.
    /// Shares the same Vision loop as `recognize(in:)` via `textFragments(in:)`.
    static func detectFragments(in image: CGImage) async -> [Fragment] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: textFragments(in: image))
            }
        }
    }

    private static func performRecognition(in image: CGImage) -> CaptureResult {
        let codeRequest = VNDetectBarcodesRequest()
        codeRequest.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]

        let codeHandler = VNImageRequestHandler(cgImage: image, options: [:])
        let payloads: [String]
        do {
            try codeHandler.perform([codeRequest])
            payloads = (codeRequest.results ?? []).compactMap(\.payloadStringValue)
        } catch {
            Log.error("QR detection failed: \(error)", log: Log.capture)
            payloads = []
        }

        let fragments = textFragments(in: image)
        return CaptureResult(text: reconstructLayout(fragments), qrPayloads: payloads)
    }

    /// The single Vision text pass used by both `recognize(in:)` and
    /// `detectFragments(in:)`: returns one `Fragment` per recognized line, with
    /// its bounding box flipped into top-left-origin pixel coordinates.
    private static func textFragments(in image: CGImage) -> [Fragment] {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            textRequest.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([textRequest])
        } catch {
            Log.error("OCR failed: \(error)", log: Log.capture)
            return []
        }

        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        return (textRequest.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { return nil }
            // Vision boxes are normalized with a bottom-left origin; flip to
            // top-left pixel coordinates.
            let bb = observation.boundingBox
            let rect = CGRect(
                x: bb.minX * w,
                y: (1 - bb.maxY) * h,
                width: bb.width * w,
                height: bb.height * h
            )
            return Fragment(text: candidate.string, rect: rect)
        }
    }

    // MARK: - Layout reconstruction

    private struct Line {
        var fragments: [Fragment]
        var midY: CGFloat
        var height: CGFloat

        var top: CGFloat { fragments.map(\.rect.minY).min() ?? 0 }
        var bottom: CGFloat { fragments.map(\.rect.maxY).max() ?? 0 }
        var minX: CGFloat { fragments.map(\.rect.minX).min() ?? 0 }
    }

    static func reconstructLayout(_ rawFragments: [Fragment]) -> String {
        let fragments = rawFragments.filter {
            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !fragments.isEmpty else { return "" }

        // Typical character width drives every horizontal decision (indents,
        // column gaps); measured from the capture itself so it is scale-free.
        var charWeight = 0.0
        var charCount = 0.0
        for f in fragments {
            charWeight += f.rect.width
            charCount += Double(f.text.count)
        }
        let charW = max(1.0, charWeight / max(1.0, charCount))

        // 1. Group fragments into visual lines by vertical-center proximity.
        let sorted = fragments.sorted { $0.rect.midY < $1.rect.midY }
        var lines: [Line] = []
        for f in sorted {
            if let i = lines.indices.last,
               abs(f.rect.midY - lines[i].midY) < 0.55 * max(lines[i].height, f.rect.height) {
                lines[i].fragments.append(f)
                let n = CGFloat(lines[i].fragments.count)
                lines[i].midY += (f.rect.midY - lines[i].midY) / n
                lines[i].height = max(lines[i].height, f.rect.height)
            } else {
                lines.append(Line(fragments: [f], midY: f.rect.midY, height: f.rect.height))
            }
        }

        // 2. Vertical metrics from the capture: median line height and the median
        //    gap between consecutive lines define what "normal" spacing means here.
        let medianHeight = median(lines.map(\.height)) ?? 12
        var gaps: [CGFloat] = []
        for i in 1..<lines.count {
            let g = lines[i].top - lines[i - 1].bottom
            if g > 0 { gaps.append(g) }
        }
        // A paragraph gap is "clearly more than this capture's normal spacing",
        // capped by an absolute rule — more than ~1.4 line-heights of air is a
        // paragraph break no matter what the local statistics say (they can be
        // skewed when the capture has only a couple of line gaps to learn from).
        let medianGap = median(gaps) ?? (medianHeight * 0.4)
        let paragraphGap = min(max(medianGap * 1.9, medianHeight * 0.85), medianHeight * 1.4)

        let leftMargin = lines.map(\.minX).min() ?? 0

        var output: [String] = []
        for (i, line) in lines.enumerated() {
            // Paragraph separation: a gap clearly larger than this capture's
            // normal line spacing, or a heading (taller than body text) ending.
            if i > 0 {
                let gap = line.top - lines[i - 1].bottom
                let previousWasHeading = lines[i - 1].height >= medianHeight * 1.3
                    && line.height < lines[i - 1].height * 0.85
                if gap > paragraphGap || (previousWasHeading && gap > medianGap * 0.5) {
                    output.append("")
                }
            }

            // Indentation in character-width columns, relative to the leftmost
            // text in the capture — keeps nested lists nested.
            let offsetCols = Int(((line.minX - leftMargin) / charW).rounded())
            let indent = String(repeating: " ", count: min(max(offsetCols, 0), 12))

            output.append(indent + normalizeListMarker(lineText(line, charW: charW)))
        }

        return output.joined(separator: "\n")
    }

    /// Join a line's fragments left-to-right; gaps much wider than a word space
    /// become proportional spacing so side-by-side content stays separated.
    private static func lineText(_ line: Line, charW: CGFloat) -> String {
        let frags = line.fragments.sorted { $0.rect.minX < $1.rect.minX }
        var text = ""
        var prevMaxX: CGFloat?
        for f in frags {
            if let prev = prevMaxX {
                let gap = f.rect.minX - prev
                if gap > charW * 2.5 {
                    let spaces = min(Int((gap / charW).rounded()), 12)
                    text += String(repeating: " ", count: max(2, spaces))
                } else if !text.hasSuffix(" ") {
                    text += " "
                }
            }
            text += f.text
            prevMaxX = max(prevMaxX ?? -.infinity, f.rect.maxX)
        }
        return text
    }

    /// Normalize the zoo of bullet glyphs OCR produces to a plain "•".
    /// Numbered / lettered markers are already literal text and pass through.
    private static func normalizeListMarker(_ text: String) -> String {
        guard let first = text.first else { return text }
        let bulletGlyphs: Set<Character> = ["•", "·", "∙", "●", "○", "◦", "‣", "▪", "▸", "■", "□", "*", "—", "–"]
        guard bulletGlyphs.contains(first) else { return text }
        let rest = text.dropFirst()
        guard rest.first == " " || rest.isEmpty else { return text }  // "*emphasis*" etc. stays
        return "•" + rest
    }

    /// Lower-middle median: with few samples this biases toward the *tight*
    /// spacing, which makes paragraph detection more willing to break — the
    /// failure mode of merging paragraphs reads worse than an extra break.
    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[(s.count - 1) / 2]
    }
}
