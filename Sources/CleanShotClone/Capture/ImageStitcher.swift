import CoreGraphics
import Foundation

/// Stitches vertically-scrolling screenshot frames at full pixel resolution.
///
/// Detection: every frame is reduced to per-row signature vectors — mean luminance
/// over `segmentCount` horizontal segments. Consecutive frames are aligned by
/// scanning vertical shifts over a center band of rows (dodging sticky headers and
/// footers). All accept thresholds are *relative*: the winning shift must clearly
/// beat the median score across all candidate shifts (what a wrong alignment costs
/// on THIS content) and the zero shift, so detection self-calibrates to dark,
/// low-contrast, or busy content instead of relying on absolute luminance numbers.
/// The worst segments are dropped from every comparison, which ignores animated
/// columns (avatars, GIFs, spinners). Ambiguous matches (periodic chat layouts) and
/// upward scrolls are rejected rather than guessed.
///
/// Composition: newly scrolled-in rows are appended below the stitched image with a
/// raw pixel copy — the accumulated image is never re-rendered. Rows pinned to the
/// bottom of the viewport (chat inputs, toolbars) are detected, withheld from every
/// append, and flushed exactly once when the session ends; the bookkeeping is
/// continuity-preserving even when the fixed-row estimate is wrong.
enum ImageStitcher {

    struct ScrollMatch {
        /// How many pixels the content scrolled down between the two frames.
        let scrollPixels: Int
        /// Rows at the bottom of the viewport that did not move with the content.
        let fixedBottomRows: Int
    }

    enum DetectResult {
        /// The viewport did not move (animation-only changes count as stationary).
        case stationary
        /// The frames differ but no confident alignment exists — wait, don't guess.
        case noMatch
        case scrolled(ScrollMatch)
    }

    // MARK: - Tuning

    /// Signature vector width per row.
    private static let segmentCount = 12
    /// Worst-matching segments ignored per comparison (dodges animated columns).
    private static let droppedSegments = 2
    private static let minScroll = 4

    // MARK: - Public API

    /// Align `next` against `previous` and report how far the content scrolled down.
    static func detectScroll(previous: CGImage, next: CGImage) -> DetectResult {
        guard previous.width == next.width, previous.height == next.height else { return .noMatch }
        let w = previous.width
        let h = previous.height
        guard h > 80 else { return .noMatch }

        guard let prevPix = rawPixels(previous), let nextPix = rawPixels(next),
              let prevSig = segmentSignatures(prevPix, width: w, height: h),
              let nextSig = segmentSignatures(nextPix, width: w, height: h) else { return .noMatch }

        let K = segmentCount

        // Texture prefix sums for `next`: a comparison window that is flat
        // background in both frames scores a vacuous, evidence-free 0 — such
        // windows may neither claim a match nor contest one as a rival.
        var deltaPrefix = [Double](repeating: 0, count: h + 1)
        for y in 0..<h {
            var d = 0.0
            if y < h - 2 {
                for k in 0..<K { d += abs(nextSig[y * K + k] - nextSig[(y + 2) * K + k]) }
                d /= Double(K)
            }
            deltaPrefix[y + 1] = deltaPrefix[y] + d
        }
        let minTexture = 0.5

        // Fixed rows at the bottom of the viewport (footers, chat inputs) are
        // identical between the frames regardless of scroll, so they can be
        // measured BEFORE alignment — and must be: prev-side comparison windows
        // that reach into a fixed footer poison the true alignment's score.
        //
        // Two estimates with different jobs: the liberal identical-row streak is
        // used for append deferral (safe by construction, flushed at Done), but
        // flat background rows that merely *coincide* between frames would crush
        // the scan range. The distinction is binary: a streak containing ANY
        // texture is a real fixed footer (borders, buttons, input pills) and the
        // whole streak limits alignment; a textureless streak is coincidental
        // background and scrolls with the content — it limits nothing.
        let fixedBottom = fixedBottomRows(prevPix, nextPix, width: w, height: h)
        var certainFixedBottom = 0
        for y in (h - fixedBottom)..<h {
            if deltaPrefix[y + 1] - deltaPrefix[y] >= minTexture {
                certainFixedBottom = fixedBottom
                break
            }
        }
        let hEff = h - certainFixedBottom

        // Compare a center band: skips sticky headers (top) and sticky footers /
        // chat inputs (bottom) that stay fixed while the content scrolls.
        let bandStart = h / 4
        let bandEnd = min((h * 3) / 4, hEff)
        // Tiny tail windows produce statistically meaningless scores — require a
        // meaningful slice of the band to overlap for a shift to be considered.
        let minRows = max(24, (bandEnd - bandStart) / 6)
        let maxScroll = hEff - bandStart - minRows
        guard maxScroll > minScroll, bandEnd - bandStart >= minRows else { return .noMatch }

        /// Trimmed L1 distance between band signatures at shift `s`
        /// (`s` > 0 = content moved up by `s` px, i.e. the user scrolled down).
        func score(_ s: Int) -> Double {
            let yStart = max(bandStart, -s)
            let yEnd = min(bandEnd, hEff - s)
            guard yEnd - yStart >= minRows else { return .infinity }
            var segSum = [Double](repeating: 0, count: K)
            var rows = 0
            var y = yStart
            while y < yEnd {
                let p = (y + s) * K
                let q = y * K
                for k in 0..<K {
                    segSum[k] += abs(prevSig[p + k] - nextSig[q + k])
                }
                rows += 1
                y += 2
            }
            guard rows > 0 else { return .infinity }
            segSum.sort()
            var total = 0.0
            for k in 0..<(K - droppedSegments) { total += segSum[k] }
            return total / Double((K - droppedSegments) * rows)
        }

        func textured(_ s: Int) -> Bool {
            let yStart = max(bandStart, -s)
            let yEnd = min(min(bandEnd, hEff - s), h - 2)
            guard yEnd > yStart else { return false }
            return (deltaPrefix[yEnd] - deltaPrefix[yStart]) / Double(yEnd - yStart) >= minTexture
        }

        // Stationary check is animation-tolerant: the trimmed score ignores the
        // worst segments, so a blinking GIF or hover highlight no longer turns an
        // idle viewport into a fake "scroll" hunt.
        let staticScore = score(0)
        if staticScore < 0.35 { return .stationary }

        var candidates: [(s: Int, score: Double)] = []
        var s = minScroll
        while s <= maxScroll {
            let sc = score(s)
            if sc.isFinite, textured(s) { candidates.append((s, sc)) }
            s += 2
        }
        guard candidates.count >= 8,
              var best = candidates.min(by: { $0.score < $1.score }) else { return .noMatch }

        // Refine ±2 around the coarse winner (scan stepped by 2).
        for cand in max(minScroll, best.s - 2)...min(maxScroll, best.s + 2) where cand != best.s {
            let sc = score(cand)
            if sc < best.score { best = (cand, sc) }
        }

        // Chance baseline: what a wrong alignment scores on this content. The
        // winner must clearly beat both chance and "didn't scroll" — relative
        // gates that hold on dark Discord themes and bright documents alike.
        let sortedScores = candidates.map(\.score).sorted()
        let baseline = sortedScores[sortedScores.count / 2]
        guard best.score < baseline * 0.45, best.score < staticScore * 0.5 else { return .noMatch }

        // Unambiguous: no rival minimum away from the winner (periodic layouts —
        // repeated chat rows, table stripes — produce several near-equal minima).
        // The segment metric can be blind to thin differences its trimming dropped,
        // so a rival only vetoes the winner if it is also pixel-real: a genuinely
        // periodic layout still vetoes, a trim-blind phantom does not.
        if let rival = candidates
            .filter({ abs($0.s - best.s) >= 12 })
            .min(by: { $0.score < $1.score }),
           rival.score < best.score * 1.25 + 0.05,
           verifyAlignment(prevPix, nextPix, width: w, effectiveHeight: hEff, height: h, shift: rival.s) {
            return .noMatch
        }

        // Upward scroll must not be mistaken for a downward one — wait it out.
        // Same rule: a negative shift only vetoes if it is pixel-real.
        var negBest: (s: Int, score: Double) = (0, .infinity)
        var neg = -minScroll
        while neg >= -(h / 2) {
            if textured(neg) {
                let sc = score(neg)
                if sc < negBest.score { negBest = (neg, sc) }
            }
            neg -= 4
        }
        if negBest.score < best.score * 1.15 + 0.02,
           verifyAlignment(prevPix, nextPix, width: w, effectiveHeight: hEff, height: h, shift: negBest.s) {
            return .noMatch
        }

        // Pixel-level verification of the winning alignment.
        guard verifyAlignment(prevPix, nextPix, width: w, effectiveHeight: hEff, height: h, shift: best.s) else {
            return .noMatch
        }

        return .scrolled(ScrollMatch(scrollPixels: best.s, fixedBottomRows: fixedBottom))
    }

    /// Append the newly scrolled-in rows of `newFrame` below `stitched`.
    ///
    /// The bottom `bottomExclude` rows of the viewport (fixed footers) are withheld
    /// from the append; when the estimate grows, the difference is trimmed off the
    /// stitched bottom so the seam stays continuous. Withheld rows are restored by
    /// `flushBottom` when the session ends.
    static func appendScroll(
        stitched: CGImage, newFrame: CGImage, scrollPixels: Int,
        previousBottomExclude: Int, bottomExclude: Int
    ) -> CGImage? {
        let h = newFrame.height
        let trim = max(0, bottomExclude - previousBottomExclude)
        let srcEnd = h - bottomExclude
        let srcStart = max(0, srcEnd - scrollPixels)
        guard srcEnd > srcStart, scrollPixels > 0, trim < stitched.height else { return nil }
        return verticalConcat(stitched, newFrame, topRows: stitched.height - trim,
                              srcStart: srcStart, srcCount: srcEnd - srcStart)
    }

    /// Append the whole visible frame after sync was lost (scrolled more than a
    /// viewport between captures) — a content gap beats a dead session.
    static func appendFullFrame(stitched: CGImage, frame: CGImage, bottomExclude: Int) -> CGImage? {
        let count = frame.height - bottomExclude
        guard count > 0 else { return nil }
        return verticalConcat(stitched, frame, topRows: stitched.height, srcStart: 0, srcCount: count)
    }

    /// Restore the withheld fixed-bottom rows (footer/chat input) exactly once.
    static func flushBottom(stitched: CGImage, lastFrame: CGImage, bottomExclude: Int) -> CGImage? {
        guard bottomExclude > 0 else { return stitched }
        let h = lastFrame.height
        guard bottomExclude < h else { return stitched }
        return verticalConcat(stitched, lastFrame, topRows: stitched.height,
                              srcStart: h - bottomExclude, srcCount: bottomExclude) ?? stitched
    }

    /// Cheap sameness test used to decide when a viewport has settled after sync
    /// was lost. Compares two sampled bands; animation keeps this false.
    static func framesRoughlyEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let h = a.height
        guard h > 80, let aPix = rawPixels(a), let bPix = rawPixels(b) else { return false }
        let rows = min(32, h / 4)
        let d1 = sampledDiff(aPix, bPix, aRow: h / 4, bRow: h / 4, rows: rows,
                             width: a.width, aHeight: h, bHeight: h)
        let d2 = sampledDiff(aPix, bPix, aRow: (h * 5) / 8, bRow: (h * 5) / 8, rows: rows,
                             width: a.width, aHeight: h, bHeight: h)
        return d1 < 1.2 && d2 < 1.2
    }

    /// A copy in the canonical RGBA layout the stitcher composes in.
    static func canonicalCopy(_ image: CGImage) -> CGImage? {
        if isCanonical(image) { return image }
        return redrawCanonical(image)
    }

    /// Downsample for live preview only — never used for the final export.
    static func previewImage(from image: CGImage, maxWidth: Int, maxHeight: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(Double(maxWidth) / Double(w), Double(maxHeight) / Double(h), 1.0)
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    // MARK: - Signatures (scroll detection)

    /// Per-row signature: mean luminance over `segmentCount` horizontal segments,
    /// flattened to `height * segmentCount` values. Channel order doesn't matter
    /// because all three color channels are summed symmetrically.
    private static func segmentSignatures(_ pix: PixelBuffer, width w: Int, height h: Int) -> [Double]? {
        let K = segmentCount
        let bpr = pix.bytesPerRow
        let rowLen = w * 4

        // Sample every 8th pixel; map each sample to a horizontal segment.
        var xs: [Int] = []
        var x = 0
        while x + 2 < rowLen {
            xs.append(x)
            x += 32
        }
        let n = xs.count
        guard n > 0 else { return nil }
        let segOf = (0..<n).map { min(K - 1, $0 * K / n) }
        var segWeight = [Double](repeating: 0, count: K)
        for i in 0..<n { segWeight[segOf[i]] += 3 }

        var sig = [Double](repeating: 0, count: h * K)
        pix.bytes.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<h {
                let rowOff = y * bpr
                guard rowOff + rowLen <= raw.count else { continue }
                let base = y * K
                for i in 0..<n {
                    let off = rowOff + xs[i]
                    sig[base + segOf[i]] += Double(Int(p[off]) + Int(p[off + 1]) + Int(p[off + 2]))
                }
            }
        }
        for y in 0..<h {
            let base = y * K
            for k in 0..<K where segWeight[k] > 0 {
                sig[base + k] /= segWeight[k]
            }
        }
        return sig
    }

    // MARK: - Pixel verification

    /// Verify the winning shift against raw pixels in up to three bands spread
    /// across the overlap. Each band is judged *relative* to a deliberately wrong
    /// control shift — absolute pixel-diff thresholds are meaningless on dark
    /// themes where most pixels match by coincidence. A 2-of-3 vote tolerates one
    /// band being covered by animation.
    private static func verifyAlignment(
        _ prevPix: PixelBuffer, _ nextPix: PixelBuffer,
        width: Int, effectiveHeight hEff: Int, height h: Int, shift s: Int
    ) -> Bool {
        let headerSkip = h / 8
        let available = (hEff - s) - headerSkip
        guard available >= 12 else { return false }
        let bandRows = min(28, available)

        var bandStarts = [headerSkip]
        if available > bandRows {
            let span = available - bandRows
            bandStarts.append(headerSkip + span / 2)
            bandStarts.append(headerSkip + span)
        }
        var seen = Set<Int>()
        bandStarts = bandStarts.filter { seen.insert($0).inserted }

        var passes = 0
        for y0 in bandStarts {
            let match = sampledDiff(prevPix, nextPix, aRow: y0 + s, bRow: y0,
                                    rows: bandRows, width: width, aHeight: h, bHeight: h)
            let controlShift = (y0 + s + 17 + bandRows <= hEff) ? s + 17 : s - 17
            let control = sampledDiff(prevPix, nextPix, aRow: y0 + controlShift, bRow: y0,
                                      rows: bandRows, width: width, aHeight: h, bHeight: h)
            if match < 1.6 {
                passes += 1
            } else if control.isFinite, control > 0, match < control * 0.4 {
                passes += 1
            }
        }
        return passes * 3 >= bandStarts.count * 2
    }

    /// Rows at the bottom of the viewport identical between the two frames even
    /// though the content scrolled — fixed footers, chat inputs, toolbars. Flat
    /// background rows can count too; that's safe, the append bookkeeping only
    /// defers them to the end of the session.
    private static func fixedBottomRows(
        _ prevPix: PixelBuffer, _ nextPix: PixelBuffer, width: Int, height h: Int
    ) -> Int {
        let cap = h / 4
        var n = 0
        while n < cap {
            let y = h - 1 - n
            let d = sampledDiff(prevPix, nextPix, aRow: y, bRow: y, rows: 1,
                                width: width, aHeight: h, bHeight: h)
            guard d < 2.0 else { break }
            n += 1
        }
        return n
    }

    /// Mean absolute per-channel difference over sampled pixels of two row ranges.
    private static func sampledDiff(
        _ a: PixelBuffer, _ b: PixelBuffer,
        aRow: Int, bRow: Int, rows: Int,
        width: Int, aHeight: Int, bHeight: Int
    ) -> Double {
        var sum = 0.0
        var count = 0.0
        a.bytes.withUnsafeBytes { aRaw in
            b.bytes.withUnsafeBytes { bRaw in
                guard let ap = aRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let bp = bRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for r in 0..<rows {
                    let ay = aRow + r, by = bRow + r
                    guard ay >= 0, ay < aHeight, by >= 0, by < bHeight else { continue }
                    let aOff = ay * a.bytesPerRow, bOff = by * b.bytesPerRow
                    guard aOff + width * 4 <= aRaw.count, bOff + width * 4 <= bRaw.count else { continue }
                    var x = 0
                    while x + 2 < width * 4 {
                        for c in 0..<3 {
                            sum += Double(abs(Int(ap[aOff + x + c]) - Int(bp[bOff + x + c])))
                            count += 1
                        }
                        x += 16 // every 4th pixel
                    }
                }
            }
        }
        return count > 0 ? sum / count : .infinity
    }

    // MARK: - Compose (append rows — never re-draw the accumulated image)

    private struct PixelBuffer {
        let bytes: Data
        let bytesPerRow: Int
    }

    /// Copy `topRows` rows of `top`, then rows `[srcStart, srcStart+srcCount)` of
    /// `bottom`, into a fresh canonical image.
    private static func verticalConcat(
        _ top: CGImage, _ bottom: CGImage,
        topRows: Int, srcStart: Int, srcCount: Int
    ) -> CGImage? {
        guard topRows > 0, topRows <= top.height,
              srcCount > 0, srcStart >= 0, srcStart + srcCount <= bottom.height,
              top.width == bottom.width else { return nil }

        // Top is always canonical (built by us); the new frame may need a layout conversion.
        guard let topPix = rawPixels(top),
              let bottomPix = canonicalPixels(bottom) else { return nil }

        let w = top.width
        let totalH = topRows + srcCount
        let destBPR = alignedBytesPerRow(width: w)
        var dest = Data(count: destBPR * totalH)

        let rowBytes = w * 4
        let copied = dest.withUnsafeMutableBytes { raw -> Bool in
            guard let dst = raw.baseAddress else { return false }
            return copyRows(from: topPix.bytes, srcBPR: topPix.bytesPerRow, srcStart: 0, count: topRows,
                            into: dst, dstBPR: destBPR, dstStart: 0, rowBytes: rowBytes)
                && copyRows(from: bottomPix.bytes, srcBPR: bottomPix.bytesPerRow, srcStart: srcStart, count: srcCount,
                            into: dst, dstBPR: destBPR, dstStart: topRows, rowBytes: rowBytes)
        }
        guard copied else { return nil }

        return makeImage(pixels: PixelBuffer(bytes: dest, bytesPerRow: destBPR),
                         width: w, height: totalH, colorSpace: top.colorSpace)
    }

    // MARK: - Pixel access & layout

    private static func rawPixels(_ image: CGImage) -> PixelBuffer? {
        guard let data = image.dataProvider?.data, CFDataGetLength(data) > 0,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        return PixelBuffer(bytes: Data(bytes: ptr, count: CFDataGetLength(data)), bytesPerRow: image.bytesPerRow)
    }

    private static func canonicalPixels(_ image: CGImage) -> PixelBuffer? {
        if isCanonical(image), let direct = rawPixels(image) { return direct }
        guard let redrawn = redrawCanonical(image) else { return nil }
        return rawPixels(redrawn)
    }

    /// Canonical layout: 32-bit RGBA, alpha last, big/default byte order.
    private static func isCanonical(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8 else { return false }
        let alpha = image.alphaInfo
        let alphaOK = alpha == .premultipliedLast || alpha == .noneSkipLast || alpha == .last
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let orderOK = order.rawValue == 0 || order == .byteOrder32Big
        return alphaOK && orderOK
    }

    /// Redraw into canonical RGBA with identity transform (row 0 = visual top).
    private static func redrawCanonical(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func makeImage(pixels: PixelBuffer, width: Int, height: Int, colorSpace: CGColorSpace?) -> CGImage? {
        let space = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixels.bytes as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func alignedBytesPerRow(width: Int) -> Int {
        ((width * 4 + 15) / 16) * 16
    }

    private static func copyRows(
        from src: Data, srcBPR: Int, srcStart: Int, count: Int,
        into dst: UnsafeMutableRawPointer, dstBPR: Int, dstStart: Int, rowBytes: Int
    ) -> Bool {
        guard srcStart >= 0, count >= 0 else { return false }
        return src.withUnsafeBytes { raw -> Bool in
            guard let srcBase = raw.baseAddress else { return false }
            for row in 0..<count {
                let sOff = (srcStart + row) * srcBPR
                let dOff = (dstStart + row) * dstBPR
                guard sOff + rowBytes <= raw.count else { return false }
                memcpy(dst.advanced(by: dOff), srcBase.advanced(by: sOff), rowBytes)
            }
            return true
        }
    }
}
