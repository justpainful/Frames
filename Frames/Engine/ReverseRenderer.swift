import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Produces a genuinely reversed copy of a clip's range.
///
/// `AVComposition` cannot play backwards, so reversal is a real render: read the
/// source range, hold its frames, and write them out in the opposite order with
/// their presentation times mirrored. The result is a new asset in the session
/// directory, and the clip is repointed at it — which is why a reversed clip
/// then trims, splits and exports exactly like any other.
///
/// This is the one operation in Frames that costs real time, so it reports
/// progress and can be cancelled.
actor ReverseRenderer {
    private let logger = FramesLog.render

    /// Reversal needs frames out of order, and holding a whole clip in memory
    /// to get them would be a disaster on a long one. Instead the source's
    /// presentation times are read first — which costs no pixels — and then
    /// frames are decoded one at a time in reverse order. Peak memory is one
    /// frame regardless of how long the clip is.
    func reverse(
        asset: SourceAsset,
        range: TimeRange,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> SourceAsset {
        let signpost = FramesLog.signposter.beginInterval("reverse")
        defer { FramesLog.signposter.endInterval("reverse", signpost) }

        try SessionPaths.createDirectories()
        let sourceURL = SessionPaths.mediaURL(for: asset.fileName)
        let source = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        guard let track = try await source.loadTracks(withMediaType: .video).first else {
            throw FramesError.unsupportedMedia("no video track to reverse")
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30

        let timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            duration: CMTime(seconds: range.duration, preferredTimescale: 600)
        )

        // Pass 1: collect presentation times, so the output can mirror them
        // without holding a single pixel.
        let times = try await presentationTimes(of: track, in: source, range: timeRange)
        guard times.count > 1 else {
            throw FramesError.renderFailed("not enough frames to reverse")
        }

        let outputName = "\(UUID().uuidString)-reversed.mov"
        let outputURL = SessionPaths.mediaURL(for: outputName)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(abs(naturalSize.width)),
            AVVideoHeightKey: Int(abs(naturalSize.height))
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // Carrying the source's transform means the reversed file is oriented
        // exactly like the original, so nothing downstream has to know.
        input.transform = preferredTransform

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(abs(naturalSize.width)),
                kCVPixelBufferHeightKey as String: Int(abs(naturalSize.height))
            ]
        )
        guard writer.canAdd(input) else {
            throw FramesError.renderFailed("the writer rejected the reversed track")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FramesError.renderFailed(writer.error?.localizedDescription ?? "writer refused to start")
        }
        writer.startSession(atSourceTime: .zero)

        let generator = AVAssetImageGenerator(asset: source)
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))

        var written = 0
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rounded()))

        do {
            for (index, sourceTime) in times.reversed().enumerated() {
                try Task.checkCancellation()

                var waited = 0
                while !input.isReadyForMoreMediaData {
                    guard waited < 2000, writer.status == .writing else {
                        throw FramesError.renderFailed("the reverse writer stalled")
                    }
                    waited += 1
                    try await Task.sleep(for: .milliseconds(5))
                }

                let (image, _) = try await generator.image(at: sourceTime)
                guard let pool = adaptor.pixelBufferPool else {
                    throw FramesError.renderFailed("no pixel buffer pool")
                }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                guard let pixelBuffer = buffer else {
                    throw FramesError.renderFailed("no pixel buffer")
                }

                autoreleasepool {
                    RenderContext.shared.export.render(
                        CIImage(cgImage: image),
                        to: pixelBuffer,
                        bounds: CGRect(origin: .zero, size: CGSize(
                            width: abs(naturalSize.width),
                            height: abs(naturalSize.height)
                        )),
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                    )
                }

                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
                adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                written += 1
                onProgress(Double(index + 1) / Double(times.count))
            }
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            if error is CancellationError { throw FramesError.cancelled }
            logger.error("Reverse failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.renderFailed(error.localizedDescription)
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw FramesError.renderFailed(writer.error?.localizedDescription ?? "reverse did not complete")
        }

        let duration = Double(written) / frameRate
        let transformed = naturalSize.applying(preferredTransform)
        return SourceAsset(
            fileName: outputName,
            kind: .video,
            duration: duration,
            displaySize: CGSize(width: abs(transformed.width), height: abs(transformed.height)),
            nominalFrameRate: frameRate,
            hasAudioTrack: false
        )
    }

    /// Reads the source's actual frame times, so the reversed file uses the
    /// frames that exist rather than a guessed grid.
    private func presentationTimes(
        of track: AVAssetTrack,
        in asset: AVAsset,
        range: CMTimeRange
    ) async throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw FramesError.renderFailed("could not read the source track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw FramesError.renderFailed("could not start reading")
        }

        var times: [CMTime] = []
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else { break }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isValid, time.isNumeric {
                times.append(time)
            }
        }
        reader.cancelReading()
        return times
    }
}
