import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import UIKit

/// Generates and caches the filmstrip thumbnails behind timeline clips.
///
/// Three rules keep this cheap enough to run while the user is pinching:
/// generation is batched through `AVAssetImageGenerator`'s async sequence,
/// results are cached by asset and rounded time so zooming reuses what is
/// already decoded, and every request carries a token so a superseded batch
/// stops decoding instead of finishing work nobody will see.
actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private struct Key: Hashable {
        let assetID: UUID
        /// Source time rounded to a quarter second, which is finer than any
        /// filmstrip needs and coarse enough to hit the cache while scrubbing.
        let quantisedTime: Int
        let height: Int
    }

    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let capacity = 320

    private var generators: [UUID: AVAssetImageGenerator] = [:]
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private let logger = FramesLog.timeline

    // MARK: - Lookup

    /// A cached thumbnail, if one is ready. Never blocks: the timeline draws a
    /// placeholder and redraws when the real frame arrives.
    func cachedThumbnail(assetID: UUID, sourceTime: TimeInterval, height: CGFloat) -> CGImage? {
        cache[key(assetID: assetID, time: sourceTime, height: height)]
    }

    /// Generates the frames a clip needs, cancelling any earlier batch for the
    /// same clip.
    func generate(
        for asset: SourceAsset,
        times: [TimeInterval],
        height: CGFloat,
        onFrame: @escaping @Sendable (TimeInterval, CGImage) async -> Void
    ) {
        inFlight[asset.id]?.cancel()

        let missing = times.filter { cache[key(assetID: asset.id, time: $0, height: height)] == nil }
        guard !missing.isEmpty else { return }

        let generator = generator(for: asset, height: height)
        let assetID = asset.id

        inFlight[assetID] = Task { [weak self] in
            let signpost = FramesLog.signposter.beginInterval("thumbnails")
            defer { FramesLog.signposter.endInterval("thumbnails", signpost) }

            let requested = missing.map { CMTime(seconds: $0, preferredTimescale: 600) }
            for await result in generator.images(for: requested) {
                if Task.isCancelled { break }
                guard let self else { break }
                do {
                    let image = try result.image
                    let time = CMTimeGetSeconds(result.requestedTime)
                    await self.store(image, assetID: assetID, time: time, height: height)
                    await onFrame(time, image)
                } catch {
                    // A single unreadable frame is not worth surfacing; the
                    // filmstrip simply keeps its placeholder there.
                    continue
                }
            }
            await self?.finish(assetID)
        }
    }

    func cancel(for assetID: UUID) {
        inFlight[assetID]?.cancel()
        inFlight[assetID] = nil
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    func purge() {
        cancelAll()
        cache.removeAll()
        order.removeAll()
        generators.removeAll()
    }

    // MARK: - Internals

    private func finish(_ assetID: UUID) {
        inFlight[assetID] = nil
    }

    private func store(_ image: CGImage, assetID: UUID, time: TimeInterval, height: CGFloat) {
        let key = key(assetID: assetID, time: time, height: height)
        cache[key] = image
        order.append(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func key(assetID: UUID, time: TimeInterval, height: CGFloat) -> Key {
        Key(
            assetID: assetID,
            quantisedTime: Int((time * 4).rounded()),
            height: Int(height.rounded())
        )
    }

    private func generator(for asset: SourceAsset, height: CGFloat) -> AVAssetImageGenerator {
        if let existing = generators[asset.id] { return existing }

        let url = SessionPaths.mediaURL(for: asset.fileName)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // A filmstrip does not need frame accuracy; letting the generator land
        // on the nearest keyframe is the difference between smooth zooming and
        // a stutter.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.35, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.35, preferredTimescale: 600)

        let aspect = asset.aspectRatio
        generator.maximumSize = CGSize(
            width: (height * aspect * 2).rounded(),
            height: (height * 2).rounded()
        )
        generators[asset.id] = generator
        return generator
    }
}
