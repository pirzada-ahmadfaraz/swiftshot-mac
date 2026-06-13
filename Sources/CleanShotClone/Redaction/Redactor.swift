import CoreGraphics

/// Paints opaque boxes over sensitive regions of a screenshot.
///
/// `rects` are in the same coordinate space as `TextRecognizer.Fragment.rect`:
/// pixel units, top-left origin. A `CGContext` is bottom-left-origin, so each
/// rect's Y is flipped before drawing.
enum Redactor {

    /// Draw solid black boxes over `rects` and return a new image. On any context
    /// failure (or when there is nothing to redact) the input is returned as-is.
    static func redact(image: CGImage, rects: [CGRect]) -> CGImage {
        guard !rects.isEmpty else { return image }

        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // Lay down the original image, then cover the sensitive regions.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let imageHeight = CGFloat(height)
        for rect in rects {
            // Flip top-left-origin pixel rect into the bottom-left CGContext space,
            // padding slightly so antialiased glyph edges are fully covered.
            let padded = rect.insetBy(dx: -2, dy: -2)
            let flipped = CGRect(
                x: padded.minX,
                y: imageHeight - padded.maxY,
                width: padded.width,
                height: padded.height
            )
            context.fill(flipped)
        }

        return context.makeImage() ?? image
    }

    /// Detect sensitive text via OCR and redact it in one call.
    /// Returns the (possibly unchanged) image and how many regions were covered.
    static func autoRedact(image: CGImage) async -> (image: CGImage, count: Int) {
        let fragments = await TextRecognizer.detectFragments(in: image)
        let rects = SensitiveDataDetector.redactionRects(fragments: fragments)
        guard !rects.isEmpty else { return (image, 0) }
        return (redact(image: image, rects: rects), rects.count)
    }
}
