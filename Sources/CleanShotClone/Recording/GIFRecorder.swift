import AVFoundation
import ScreenCaptureKit
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

/// Records a display region to an animated GIF.
///
/// Frames stream in at the GIF frame rate and are spooled to disk as JPEGs (so
/// long recordings never blow up memory); on stop they're assembled into a GIF
/// with true per-frame delays. Pause works like the video recorder: frames are
/// dropped and the timestamps of everything after the pause are shifted back.
final class GIFRecorder: NSObject, SCStreamDelegate, SCStreamOutput {

    struct Options {
        /// Region in display-local points, top-left origin. nil = whole display.
        var sourceRect: CGRect?
        var scale: CGFloat = 1
        var fps: Int = 12
        var showsCursor = true
        var excludingWindows: [SCWindow] = []
    }

    private var stream: SCStream?
    private let processingQueue = DispatchQueue(label: "com.ahmadfaraz.cleanshotclone.gifrecorder")
    private var spoolDir: URL?
    private var frameTimes: [Double] = []   // seconds, pause-adjusted
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var isPaused = false
    private var needsOffsetRecalc = false
    private var timeOffset = CMTime.zero
    private var frameDuration = CMTime(value: 1, timescale: 12)
    /// Called on processingQueue when the stream stops unexpectedly.
    var onStreamError: ((Error) -> Void)?

    func start(display: SCDisplay, options: Options) async throws {
        precondition(stream == nil, "Already recording")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let region = options.sourceRect ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let config = SCStreamConfiguration()
        config.width = max(Int(region.width * options.scale) & ~1, 2)
        config.height = max(Int(region.height * options.scale) & ~1, 2)
        if options.sourceRect != nil { config.sourceRect = region }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(options.fps, 1)))
        config.showsCursor = options.showsCursor
        config.queueDepth = 6
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(options.fps, 1)))

        let filter = SCContentFilter(display: display, excludingWindows: options.excludingWindows)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)

        // Assign spool dir before startCapture so early frames aren't dropped.
        processingQueue.sync {
            self.spoolDir = dir
            self.frameTimes = []
            self.firstPTS = nil
            self.lastPTS = nil
            self.isPaused = false
            self.needsOffsetRecalc = false
            self.timeOffset = .zero
        }
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            processingQueue.sync {
                self.spoolDir = nil
                self.stream = nil
            }
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    func pause() {
        processingQueue.async { self.isPaused = true }
    }

    func resume() {
        processingQueue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            self.needsOffsetRecalc = true
        }
    }

    /// Swap the capture filter mid-recording (e.g. to exclude the annotation
    /// toolbar). Only the filter changes — resolution, sourceRect and fps persist.
    func updateContentFilter(_ filter: SCContentFilter) async {
        guard let stream else { return }
        try? await stream.updateContentFilter(filter)
    }

    /// Stop capturing and assemble the GIF. Returns nil if no frames arrived.
    func stop() async throws -> URL? {
        guard let stream else { return nil }
        try? await stream.stopCapture()
        self.stream = nil

        let (dir, times): (URL?, [Double]) = processingQueue.sync { (spoolDir, frameTimes) }
        processingQueue.sync { self.spoolDir = nil }
        guard let dir else {
            throw NSError(domain: "GIFRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Internal recorder state was lost."])
        }
        guard !times.isEmpty else {
            try? FileManager.default.removeItem(at: dir)
            throw NSError(domain: "GIFRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No frames were captured. Record for at least one frame interval."])
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recording-\(UUID().uuidString).gif")
        let ok = await Task.detached(priority: .userInitiated) {
            Self.assembleGIF(frameDir: dir, times: times, to: outputURL)
        }.value
        try? FileManager.default.removeItem(at: dir)
        guard ok else {
            try? FileManager.default.removeItem(at: outputURL)
            throw NSError(domain: "GIFRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to assemble the GIF from captured frames."])
        }
        return outputURL
    }

    /// Delete spooled frames without producing a file.
    func discard() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        processingQueue.sync {
            if let dir = spoolDir { try? FileManager.default.removeItem(at: dir) }
            spoolDir = nil
            frameTimes = []
        }
    }

    // MARK: - Frames (processingQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let dir = spoolDir else { return }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRaw = attachments[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isPaused { return }
        if needsOffsetRecalc {
            if let last = lastPTS {
                let gap = CMTimeSubtract(CMTimeSubtract(pts, last), frameDuration)
                if gap > .zero { timeOffset = CMTimeAdd(timeOffset, gap) }
            }
            needsOffsetRecalc = false
        }
        let adjusted = CMTimeSubtract(pts, timeOffset)
        if firstPTS == nil { firstPTS = adjusted }
        lastPTS = pts

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard let image = cgImage else { return }

        let index = frameTimes.count
        let url = dir.appendingPathComponent(String(format: "%06d.jpg", index))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        frameTimes.append(CMTimeSubtract(adjusted, firstPTS ?? adjusted).seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("GIF SCStream stopped with error: \(error)", log: Log.recording)
        processingQueue.async { [weak self] in
            self?.onStreamError?(error)
        }
    }

    // MARK: - Assembly

    private static func assembleGIF(frameDir: URL, times: [Double], to outputURL: URL) -> Bool {
        let frameURLs = (0..<times.count).map { frameDir.appendingPathComponent(String(format: "%06d.jpg", $0)) }
        var delays: [Double] = []
        for i in 0..<times.count {
            let d: Double
            if i + 1 < times.count {
                d = times[i + 1] - times[i]
            } else if let last = delays.last {
                d = last
            } else {
                d = 1.0 / 12.0
            }
            delays.append(max(d, 0.02))
        }
        return GIFFile.write(frameURLs: frameURLs, delays: delays, to: outputURL)
    }
}

/// Shared GIF encode/decode helpers — used by the recorder and the trim editor.
enum GIFFile {

    /// Stream frames from disk into an animated GIF (memory stays flat).
    static func write(frameURLs: [URL], delays: [Double], to outputURL: URL) -> Bool {
        guard !frameURLs.isEmpty, frameURLs.count == delays.count,
              let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, frameURLs.count, nil) else { return false }

        let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, fileProps)

        for (url, delay) in zip(frameURLs, delays) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
            addFrame(image, delay: delay, to: dest)
        }
        return CGImageDestinationFinalize(dest)
    }

    /// Re-encode a sub-range of an existing GIF (the trim operation).
    static func trim(_ url: URL, from startSeconds: Double, to endSeconds: Double, output: URL) -> Bool {
        let frames = frameInfo(of: url)
        guard !frames.isEmpty, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }

        var kept: [(index: Int, delay: Double)] = []
        var t = 0.0
        for (i, delay) in frames.enumerated() {
            if t >= startSeconds - 0.001 && t < endSeconds - 0.001 {
                kept.append((i, delay))
            }
            t += delay
        }
        guard !kept.isEmpty,
              let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, kept.count, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, delay) in kept {
            guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else { continue }
            addFrame(image, delay: delay, to: dest)
        }
        return CGImageDestinationFinalize(dest)
    }

    /// Per-frame delays (seconds) of an animated GIF.
    static func frameInfo(of url: URL) -> [Double] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(src)
        return (0..<count).map { i in
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
            let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
            let d = unclamped ?? clamped ?? 0.1
            return d > 0.001 ? d : 0.1
        }
    }

    static func totalDuration(of url: URL) -> Double {
        frameInfo(of: url).reduce(0, +)
    }

    /// Evenly-spaced thumbnail frames for a filmstrip.
    static func thumbnails(of url: URL, count: Int, maxHeight: Int) -> [CGImage] {
        guard count > 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let total = CGImageSourceGetCount(src)
        guard total > 0 else { return [] }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxHeight * 4,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        return (0..<count).compactMap { i in
            let index = min(total - 1, i * total / count)
            return CGImageSourceCreateThumbnailAtIndex(src, index, opts)
        }
    }

    static func firstFrame(of url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func addFrame(_ image: CGImage, delay: Double, to dest: CGImageDestination) {
        let props = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFUnclampedDelayTime: delay,
            kCGImagePropertyGIFDelayTime: delay
        ]] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
    }
}
