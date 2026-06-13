import SwiftUI
import CoreGraphics

/// Helpers for the freehand marker / highlighter tool.
enum MarkerStroke {
    static let defaultColor = Color(red: 0.78, green: 0.98, blue: 0.38)
    static let fillOpacity: CGFloat = 0.45

    /// Samples the image under `canvasPoint` to estimate text-line height for stroke width.
    static func estimateWidth(at canvasPoint: CGPoint, canvasSize: CGSize, image: CGImage) -> CGFloat {
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        guard imgW > 1, imgH > 1, canvasSize.width > 1, canvasSize.height > 1 else {
            return fallbackWidth(canvasSize)
        }

        let px = Int((canvasPoint.x / canvasSize.width * imgW).rounded())
        let py = Int((canvasPoint.y / canvasSize.height * imgH).rounded())
        let halfW = max(6, Int(imgW * 0.015))
        let halfH = max(24, Int(imgH * 0.06))

        let x0 = max(0, px - halfW), x1 = min(Int(imgW) - 1, px + halfW)
        let y0 = max(0, py - halfH), y1 = min(Int(imgH) - 1, py + halfH)
        guard x1 > x0, y1 > y0,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return fallbackWidth(canvasSize)
        }

        let bpp = image.bitsPerPixel / 8
        let rowBytes = image.bytesPerRow
        guard bpp >= 3 else { return fallbackWidth(canvasSize) }

        var rowLuma: [CGFloat] = []
        rowLuma.reserveCapacity(y1 - y0 + 1)
        for y in y0...y1 {
            var sum: CGFloat = 0
            var count: CGFloat = 0
            for x in x0...x1 {
                let off = y * rowBytes + x * bpp
                let r = CGFloat(ptr[off]) / 255
                let g = CGFloat(ptr[off + 1]) / 255
                let b = CGFloat(ptr[off + 2]) / 255
                sum += 0.299 * r + 0.587 * g + 0.114 * b
                count += 1
            }
            rowLuma.append(sum / max(count, 1))
        }

        let mean = rowLuma.reduce(0, +) / CGFloat(rowLuma.count)
        let threshold = mean - 0.08
        var bestLen = 0, bestStart = 0, curLen = 0, curStart = 0
        for (i, l) in rowLuma.enumerated() {
            if l < threshold {
                if curLen == 0 { curStart = i }
                curLen += 1
                if curLen > bestLen { bestLen = curLen; bestStart = curStart }
            } else {
                curLen = 0
            }
        }

        let centerRow = py - y0
        if bestLen >= 3, centerRow >= bestStart, centerRow < bestStart + bestLen {
            let bandPx = CGFloat(bestLen)
            let canvasW = bandPx * (canvasSize.height / imgH)
            return min(max(canvasW * 1.15, 10), canvasSize.height * 0.12)
        }

        // Fallback: local contrast — measure vertical edge density near the point.
        var edgeSpans: [Int] = []
        var span = 0
        for i in 1..<rowLuma.count {
            if abs(rowLuma[i] - rowLuma[i - 1]) > 0.04 {
                if span > 0 { edgeSpans.append(span); span = 0 }
            } else {
                span += 1
            }
        }
        if let median = edgeSpans.sorted().dropFirst(edgeSpans.count / 2).first, median > 2 {
            let canvasW = CGFloat(median) * (canvasSize.height / imgH)
            return min(max(canvasW * 1.2, 10), canvasSize.height * 0.12)
        }

        return fallbackWidth(canvasSize)
    }

    private static func fallbackWidth(_ canvasSize: CGSize) -> CGFloat {
        max(14, canvasSize.height * 0.032)
    }

    static func path(from points: [CGPoint], scaleX: CGFloat, scaleY: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x * scaleX, y: first.y * scaleY))
        for p in points.dropFirst() {
            path.addLine(to: CGPoint(x: p.x * scaleX, y: p.y * scaleY))
        }
        return path
    }

    static func hitTest(point: CGPoint, points: [CGPoint], width: CGFloat, sx: CGFloat, sy: CGFloat, tolerance: CGFloat = 6) -> Bool {
        let half = width * (sx + sy) / 2 / 2 + tolerance
        guard points.count >= 2 else {
            if let p = points.first {
                let sp = CGPoint(x: p.x * sx, y: p.y * sy)
                return hypot(point.x - sp.x, point.y - sp.y) <= half
            }
            return false
        }
        for i in 0..<(points.count - 1) {
            let a = CGPoint(x: points[i].x * sx, y: points[i].y * sy)
            let b = CGPoint(x: points[i + 1].x * sx, y: points[i + 1].y * sy)
            if pointToSegmentDistance(point, a, b) <= half { return true }
        }
        return false
    }

    private static func pointToSegmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Drop points closer than `minDist` to keep strokes smooth and lightweight.
    static func simplified(_ points: [CGPoint], minDist: CGFloat = 2.5) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var out = [last]
        for p in points.dropFirst() {
            if hypot(p.x - last.x, p.y - last.y) >= minDist {
                out.append(p)
                last = p
            }
        }
        return out
    }
}
