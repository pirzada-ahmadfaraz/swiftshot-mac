import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Records a display region to an MP4 using ScreenCaptureKit + AVAssetWriter.
///
/// Supports: region capture (sourceRect), configurable fps/cursor/scale, system
/// audio (SCStream audio output), microphone (parallel AVCaptureSession), and
/// pause/resume — implemented by dropping buffers while paused and shifting all
/// subsequent presentation timestamps back by the accumulated pause duration, so
/// the output file has no gap.
final class ScreenRecorder: NSObject, SCStreamDelegate, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {

    struct Options {
        /// Region in display-local points, top-left origin. nil = whole display.
        var sourceRect: CGRect?
        var scale: CGFloat = 2
        var fps: Int = 60
        var showsCursor = true
        var captureSystemAudio = false
        var captureMicrophone = false
        var excludingWindows: [SCWindow] = []
    }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micSession: AVCaptureSession?
    private var sessionStarted = false
    private let processingQueue = DispatchQueue(label: "com.ahmadfaraz.cleanshotclone.recorder")
    private var outputURL: URL?

    // Pause state — only touched on processingQueue.
    private var isPaused = false
    private var timeOffset = CMTime.zero
    private var lastVideoPTS: CMTime?
    private var needsOffsetRecalc = false
    private var frameDuration = CMTime(value: 1, timescale: 60)
    /// Called on processingQueue when the stream stops unexpectedly.
    var onStreamError: ((Error) -> Void)?

    /// Begin recording to `outputURL`.
    func start(display: SCDisplay, options: Options, outputURL: URL) async throws {
        precondition(stream == nil, "Already recording")
        self.outputURL = outputURL

        let region = options.sourceRect ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
        // H.264 requires even dimensions.
        let pxWidth = max(Int(region.width * options.scale) & ~1, 2)
        let pxHeight = max(Int(region.height * options.scale) & ~1, 2)

        let config = SCStreamConfiguration()
        config.width = pxWidth
        config.height = pxHeight
        if options.sourceRect != nil { config.sourceRect = region }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(options.fps, 1)))
        config.showsCursor = options.showsCursor
        config.queueDepth = 6
        if options.captureSystemAudio {
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
        }
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(options.fps, 1)))

        let filter = SCContentFilter(display: display, excludingWindows: options.excludingWindows)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pxWidth,
            AVVideoHeightKey: pxHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(pxWidth * pxHeight * 8, 6_000_000),
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        systemAudioInput = nil
        micInput = nil
        var systemAudio: AVAssetWriterInput?
        var micAudio: AVAssetWriterInput?
        if options.captureSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            systemAudio = input
        }
        if options.captureMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micAudio = input
            setUpMicSession()
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: processingQueue)
        if options.captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
        }

        guard writer.startWriting() else {
            tearDownMicSession()
            throw NSError(domain: "ScreenRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")"])
        }

        // Assign state before startCapture so the first frames aren't dropped.
        processingQueue.sync {
            self.isPaused = false
            self.timeOffset = .zero
            self.lastVideoPTS = nil
            self.needsOffsetRecalc = false
            self.sessionStarted = false
        }
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudio
        self.micInput = micAudio
        self.stream = stream

        do {
            try await stream.startCapture()
        } catch {
            processingQueue.sync {
                self.writer = nil
                self.videoInput = nil
                self.systemAudioInput = nil
                self.micInput = nil
                self.stream = nil
            }
            tearDownMicSession()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            self.outputURL = nil
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

    /// Stops recording and finalizes the output file. Returns the URL on success.
    func stop() async throws -> URL? {
        guard let stream, let writer, let outputURL else { return nil }
        try? await stream.stopCapture()
        tearDownMicSession()

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        if writer.status == .writing {
            await writer.finishWriting()
        }

        let error = writer.status == .failed ? writer.error : nil
        self.stream = nil
        self.writer = nil
        self.videoInput = nil
        self.systemAudioInput = nil
        self.micInput = nil
        self.outputURL = nil
        if let error { throw error }
        return outputURL
    }

    /// Stop capture and discard the partial file without finalizing.
    func cancel() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        tearDownMicSession()

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        if let writer, writer.status == .writing {
            writer.cancelWriting()
        }
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }

        self.stream = nil
        self.writer = nil
        self.videoInput = nil
        self.systemAudioInput = nil
        self.micInput = nil
        self.outputURL = nil
        processingQueue.sync {
            self.isPaused = false
            self.timeOffset = .zero
            self.lastVideoPTS = nil
            self.needsOffsetRecalc = false
            self.sessionStarted = false
        }
    }

    // MARK: - Microphone

    private func setUpMicSession() {
        // Belt-and-suspenders: touching the device without authorization (or
        // without a usage description in Info.plist) gets the process killed
        // by TCC. The session layer already gates on this; never trust it.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Log.error("Mic session skipped — not authorized", log: Log.recording)
            return
        }
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Log.error("No microphone available", log: Log.recording)
            return
        }
        let session = AVCaptureSession()
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: processingQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        micSession = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func tearDownMicSession() {
        let session = micSession
        micSession = nil
        DispatchQueue.global(qos: .userInitiated).async { session?.stopRunning() }
    }

    // MARK: - Sample handling (processingQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, writer != nil else { return }
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            append(sampleBuffer, to: systemAudioInput)
        default:
            break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sampleBuffer, to: micInput)
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let writer, let input = videoInput else { return }

        // Skip non-complete frames (drops, idle, etc.)
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let attachments = attachmentsArray.first,
           let statusRaw = attachments[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if isPaused {
            return
        }
        if needsOffsetRecalc {
            // First frame after a pause: everything between the last appended
            // frame and now was "the pause" — fold it into the offset so the
            // output timeline is continuous.
            if let last = lastVideoPTS {
                let gap = CMTimeSubtract(CMTimeSubtract(pts, last), frameDuration)
                if gap > .zero { timeOffset = CMTimeAdd(timeOffset, gap) }
            }
            needsOffsetRecalc = false
        }

        if !sessionStarted {
            writer.startSession(atSourceTime: CMTimeSubtract(pts, timeOffset))
            sessionStarted = true
        }
        lastVideoPTS = pts

        guard input.isReadyForMoreMediaData else { return }
        if let shifted = retimed(sampleBuffer, by: timeOffset) {
            input.append(shifted)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, sessionStarted, !isPaused, !needsOffsetRecalc,
              input.isReadyForMoreMediaData else { return }
        if let shifted = retimed(sampleBuffer, by: timeOffset) {
            input.append(shifted)
        }
    }

    private func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<count {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &out
        )
        return out
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("SCStream stopped with error: \(error)", log: Log.recording)
        processingQueue.async { [weak self] in
            self?.onStreamError?(error)
        }
    }
}
