import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import OSLog

/// A downsampled amplitude envelope for drawing an audio clip.
struct Waveform: Sendable, Hashable {
    /// Peak magnitude per bucket, 0...1.
    let samples: [Float]
    let duration: TimeInterval

    static let empty = Waveform(samples: [], duration: 0)

    /// The value to draw at a normalized position across the clip.
    func value(at progress: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let index = Int(min(max(progress, 0), 0.999) * Double(samples.count))
        return samples[min(index, samples.count - 1)]
    }
}

/// Reads audio and reduces it to something drawable.
///
/// Runs entirely off the main actor and caches by asset, because a waveform is
/// expensive to compute and never changes for a given file. The read is
/// streamed sample-block by sample-block rather than loaded whole, so a
/// ten-minute track costs the same memory as a ten-second one.
actor AudioWaveformGenerator {
    static let shared = AudioWaveformGenerator()

    private var cache: [Key: Waveform] = [:]
    private var inFlight: [Key: Task<Waveform, Error>] = [:]
    private let logger = FramesLog.audio

    private struct Key: Hashable {
        let fileName: String
        let bucketCount: Int
    }

    func waveform(for asset: SourceAsset, bucketCount: Int = 400) async throws -> Waveform {
        let key = Key(fileName: asset.fileName, bucketCount: bucketCount)
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return try await existing.value }

        let url = SessionPaths.mediaURL(for: asset.fileName)
        let task = Task<Waveform, Error> {
            try await Self.compute(url: url, bucketCount: bucketCount)
        }
        inFlight[key] = task

        do {
            let waveform = try await task.value
            cache[key] = waveform
            inFlight[key] = nil
            return waveform
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func cachedWaveform(for asset: SourceAsset, bucketCount: Int = 400) -> Waveform? {
        cache[Key(fileName: asset.fileName, bucketCount: bucketCount)]
    }

    func purge() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
    }

    // MARK: - Reading

    private static func compute(url: URL, bucketCount: Int) async throws -> Waveform {
        let signpost = FramesLog.signposter.beginInterval("waveform")
        defer { FramesLog.signposter.endInterval("waveform", signpost) }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return .empty
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .empty }
        reader.add(output)
        guard reader.startReading() else { return .empty }

        var buckets = [Float](repeating: 0, count: max(bucketCount, 1))
        var totalSamples = 0
        var pending: [Float] = []

        // Estimate how many samples land in one bucket so the envelope is even
        // across the file rather than bunched at the start.
        let sampleRate = 44_100.0
        let estimatedTotal = max(Int(duration * sampleRate), bucketCount)
        let perBucket = max(estimatedTotal / max(bucketCount, 1), 1)

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            try Task.checkCancellation()

            autoreleasepool {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                guard length > 0 else { return }

                var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                data.withUnsafeMutableBytes { pointer in
                    guard let base = pointer.baseAddress else { return }
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: length,
                        destination: base
                    )
                }

                // Rectify, then take the peak of each bucket: peaks read better
                // than an RMS envelope at timeline sizes.
                var magnitudes = [Float](repeating: 0, count: data.count)
                vDSP_vabs(data, 1, &magnitudes, 1, vDSP_Length(data.count))
                pending.append(contentsOf: magnitudes)
                totalSamples += data.count

                while pending.count >= perBucket {
                    let slice = Array(pending.prefix(perBucket))
                    pending.removeFirst(perBucket)
                    var peak: Float = 0
                    vDSP_maxv(slice, 1, &peak, vDSP_Length(slice.count))
                    let index = min(bucketIndex(processed: totalSamples - pending.count,
                                                perBucket: perBucket,
                                                limit: buckets.count), buckets.count - 1)
                    buckets[index] = max(buckets[index], peak)
                }
            }
        }

        if !pending.isEmpty {
            var peak: Float = 0
            vDSP_maxv(pending, 1, &peak, vDSP_Length(pending.count))
            buckets[buckets.count - 1] = max(buckets[buckets.count - 1], peak)
        }

        reader.cancelReading()

        // Normalise so quiet recordings still fill the strip.
        let maximum = buckets.max() ?? 0
        if maximum > 0.0001 {
            buckets = buckets.map { min($0 / maximum, 1) }
        }
        return Waveform(samples: buckets, duration: duration)
    }

    private static func bucketIndex(processed: Int, perBucket: Int, limit: Int) -> Int {
        max(0, min(processed / max(perBucket, 1) - 1, limit - 1))
    }
}
