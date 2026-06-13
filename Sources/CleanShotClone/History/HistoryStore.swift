import AppKit
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

/// The capture library: copies every still/recording into Application Support and
/// keeps a JSON index alongside the assets. Singleton, main-actor (it owns disk
/// state read by the History window). The pure `filter(items:query:)` core and the
/// Codable model live in `HistoryModel.swift` so they can be harness-tested.
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    /// Longest edge of a generated thumbnail, in pixels.
    private static let thumbnailMaxDimension: CGFloat = 400
    /// Hard cap on library size; oldest entries (assets + thumbnails) are evicted on add.
    private static let maxItems = 500

    /// ~/Library/Application Support/SwiftShot/Library/
    let libraryDirectory: URL
    private var indexURL: URL { libraryDirectory.appendingPathComponent("index.json") }

    private var index: [HistoryItem] = []

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        libraryDirectory = support
            .appendingPathComponent("SwiftShot", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        index = Self.loadIndex(from: indexURL)
    }

    // MARK: - Adding

    /// Persist a still capture: full-resolution PNG + downsampled thumbnail.
    func add(image: CGImage, sourceApp: String?, ocrText: String?) {
        let id = UUID()
        let assetName = "\(id.uuidString).png"
        let thumbName = "\(id.uuidString)-thumb.png"
        let assetURL = libraryDirectory.appendingPathComponent(assetName)
        let thumbURL = libraryDirectory.appendingPathComponent(thumbName)

        guard let assetData = Self.pngData(from: image) else {
            Log.error("History: failed to encode capture PNG", log: Log.general)
            return
        }
        do {
            try assetData.write(to: assetURL, options: .atomic)
        } catch {
            Log.error("History: failed to write asset: \(error)", log: Log.general)
            return
        }
        Self.writeThumbnail(from: image, to: thumbURL)

        let item = HistoryItem(
            id: id, type: .image,
            assetPath: assetName, thumbnailPath: thumbName,
            createdAt: Date(), sourceApp: sourceApp, ocrText: ocrText
        )
        append(item)
    }

    /// Persist a finished recording: copy the file in + generate a poster-frame thumbnail.
    func add(mediaURL: URL, kind: MediaKind, sourceApp: String? = nil) {
        let id = UUID()
        let ext = kind.fileExtension
        let assetName = "\(id.uuidString).\(ext)"
        let thumbName = "\(id.uuidString)-thumb.png"
        let assetURL = libraryDirectory.appendingPathComponent(assetName)
        let thumbURL = libraryDirectory.appendingPathComponent(thumbName)

        do {
            if FileManager.default.fileExists(atPath: assetURL.path) {
                try FileManager.default.removeItem(at: assetURL)
            }
            try FileManager.default.copyItem(at: mediaURL, to: assetURL)
        } catch {
            Log.error("History: failed to copy media: \(error)", log: Log.general)
            return
        }

        if let poster = Self.posterFrame(for: assetURL, kind: kind) {
            Self.writeThumbnail(from: poster, to: thumbURL)
        }

        let item = HistoryItem(
            id: id, type: kind == .video ? .video : .gif,
            assetPath: assetName, thumbnailPath: thumbName,
            createdAt: Date(), sourceApp: sourceApp, ocrText: nil
        )
        append(item)
    }

    // MARK: - Querying

    /// All items, newest first.
    func items() -> [HistoryItem] {
        index.sorted { $0.createdAt > $1.createdAt }
    }

    /// Newest-first items matching `query` (see `filter`).
    func search(_ query: String) -> [HistoryItem] {
        Self.filter(items: items(), query: query)
    }

    func assetURL(for item: HistoryItem) -> URL {
        libraryDirectory.appendingPathComponent(item.assetPath)
    }

    func thumbnailURL(for item: HistoryItem) -> URL {
        libraryDirectory.appendingPathComponent(item.thumbnailPath)
    }

    /// Load the full-resolution asset of an image item as a CGImage (nil for media).
    func loadImage(for item: HistoryItem) -> CGImage? {
        guard item.type == .image else { return nil }
        let url = assetURL(for: item)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Deleting

    /// Remove an item's asset + thumbnail from disk and drop it from the index.
    func delete(id: UUID) {
        guard let item = index.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: assetURL(for: item))
        try? FileManager.default.removeItem(at: thumbnailURL(for: item))
        index.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Index bookkeeping

    private func append(_ item: HistoryItem) {
        index.append(item)
        evictIfNeeded()
        persist()
    }

    /// Keep at most `maxItems`; remove oldest assets + entries first.
    private func evictIfNeeded() {
        guard index.count > Self.maxItems else { return }
        let sortedOldestFirst = index.sorted { $0.createdAt < $1.createdAt }
        let overflow = index.count - Self.maxItems
        for victim in sortedOldestFirst.prefix(overflow) {
            try? FileManager.default.removeItem(at: assetURL(for: victim))
            try? FileManager.default.removeItem(at: thumbnailURL(for: victim))
            index.removeAll { $0.id == victim.id }
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(index) else {
            Log.error("History: failed to encode index", log: Log.general)
            return
        }
        do {
            try data.write(to: indexURL, options: .atomic)
        } catch {
            Log.error("History: failed to write index: \(error)", log: Log.general)
        }
    }

    private static func loadIndex(from url: URL) -> [HistoryItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    // MARK: - Image helpers (private — see contract §2: no public free functions)

    private static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Downsample to `thumbnailMaxDimension` longest-edge and write a PNG.
    private static func writeThumbnail(from image: CGImage, to url: URL) {
        let thumb = downsample(image, maxDimension: thumbnailMaxDimension) ?? image
        guard let data = pngData(from: thumb) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Aspect-preserving downsample. Returns nil if the image already fits.
    private static func downsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longest = max(w, h)
        guard longest > maxDimension else { return nil }
        let scale = maxDimension / longest
        let newW = max(Int((w * scale).rounded()), 1)
        let newH = max(Int((h * scale).rounded()), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    /// First/poster frame for a recording (GIF = frame 0, video = t≈0).
    private static func posterFrame(for url: URL, kind: MediaKind) -> CGImage? {
        switch kind {
        case .gif:
            return GIFFile.firstFrame(of: url)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1200, height: 0)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }
    }
}
