import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OSLog

/// Everything that happens on the capture queue.
///
/// Split out of `CameraService` so there is exactly one object the video queue
/// touches. The service stays on the main actor and owns interface state; this
/// owns the frames, the writer and the Portrait temporal state, and is only
/// ever entered from the capture queue or behind its own lock.
final class CaptureRecorder: NSObject, @unchecked Sendable {

    /// Reads the live Portrait settings. A closure rather than a stored copy so
    /// moving a slider changes the very next frame, including mid-recording.
    var portraitProvider: (() -> PortraitSettings)?
    var onFrame: ((CIImage) -> Void)?
    var onDurationChange: ((TimeInterval) -> Void)?

    private let lock = NSLock()
    private var latestImage: CIImage?

    /// Carried between frames so the processing does not flicker while the
    /// subject moves — the same state the video compositor uses.
    private let portraitState = PortraitTemporalState()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var sessionStart: CMTime?
    private var isWriting = false
    private var wantsToWrite = false

    private let logger = FramesLog.render

    // MARK: - Recording control

    func begin() {
        lock.lock()
        wantsToWrite = true
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let writer = self.writer
        let url = outputURL
        tearDownWriter()
        lock.unlock()

        writer?.cancelWriting()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func finish() async throws -> URL {
        lock.lock()
        let writer = self.writer
        let video = videoInput
        let audio = audioInput
        let url = outputURL
        let wrote = isWriting
        tearDownWriter()
        lock.unlock()

        guard let writer, let url, wrote else {
            throw FramesError.exportFailed("the recording never started")
        }
        video?.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw FramesError.exportFailed(
                writer.error?.localizedDescription ?? "the recording did not finish"
            )
        }
        return url
    }

    func latestProcessedImage() -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return latestImage
    }

    /// Must be called with the lock held.
    private func tearDownWriter() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        outputURL = nil
        sessionStart = nil
        isWriting = false
        wantsToWrite = false
    }

    // MARK: - Frames

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(time)

        autoreleasepool {
            let source = CIImage(cvPixelBuffer: pixelBuffer)
            let settings = portraitProvider?() ?? .off

            var output = source
            if settings.isActive {
                // No person mask here: running segmentation on every captured
                // frame would not keep up, and the temporal state plus the
                // edge-aware smoothing already keep the processing off the
                // structural detail. The mask path is available once the clip
                // is in the editor.
                output = PortraitProcessor.apply(
                    settings,
                    to: source,
                    personMask: nil,
                    state: portraitState,
                    time: seconds.isFinite ? seconds : 0,
                    quality: .interactive
                )
            }

            lock.lock()
            latestImage = output
            lock.unlock()

            onFrame?(output)
            appendVideo(output, at: time, size: source.extent.size)
        }
    }

    private func appendVideo(_ image: CIImage, at time: CMTime, size: CGSize) {
        lock.lock()

        if wantsToWrite, writer == nil {
            startWriter(size: size)
        }
        guard let writer, let videoInput, let adaptor, isWriting || sessionStart == nil else {
            lock.unlock()
            return
        }

        if sessionStart == nil {
            writer.startSession(atSourceTime: time)
            sessionStart = time
            isWriting = true
        }
        let start = sessionStart
        let ready = videoInput.isReadyForMoreMediaData
        lock.unlock()

        guard ready, let start else { return }

        guard let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let destination = buffer else { return }

        RenderContext.shared.preview.render(
            image,
            to: destination,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
        adaptor.append(destination, withPresentationTime: time)

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(time, start))
        if elapsed.isFinite {
            onDurationChange?(max(elapsed, 0))
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let input = audioInput
        let started = sessionStart != nil
        lock.unlock()

        // Audio before the first video frame has nowhere to go: the session
        // has not been started and its timestamps would be negative.
        guard started, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// Must be called with the lock held.
    private func startWriter(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        do {
            try SessionPaths.createDirectories()
            let url = SessionPaths.mediaURL(for: "\(UUID().uuidString).mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            video.expectsMediaDataInRealTime = true

            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: video,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height)
                ]
            )
            guard writer.canAdd(video) else { return }
            writer.add(video)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                self.audioInput = audio
            }

            guard writer.startWriting() else { return }

            self.writer = writer
            self.videoInput = video
            self.adaptor = adaptor
            self.outputURL = url
        } catch {
            logger.error("Could not start the recorder: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Capture delegates

extension CaptureRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            appendAudio(sampleBuffer)
        } else {
            process(sampleBuffer)
        }
    }
}
