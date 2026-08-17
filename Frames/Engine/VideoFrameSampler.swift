import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import OSLog

/// Pulls a single ungraded frame out of a video.
///
/// Used by anything that needs to look at the picture rather than play it:
/// Auto Enhance, filter thumbnails, starting an object track, and the face and
/// person pickers.
enum VideoFrameSampler {

    /// The source frame at a timeline position, with the track's preferred
    /// transform applied so it is the right way up.
    static func frame(
        at time: TimeInterval,
        in document: EditDocument,
        maxPixelSize: CGFloat = 1024
    ) async -> CIImage? {
        guard document.kind == .video,
              let located = document.clip(at: time),
              let assetDescription = document.asset(id: located.clip.assetID)
        else { return nil }

        let sourceTime = located.clip.sourceTime(forOffset: located.offset)
        return await frame(
            at: sourceTime,
            ofAsset: assetDescription,
            maxPixelSize: maxPixelSize
        )
    }

    /// A frame at a source time in a specific asset.
    static func frame(
        at sourceTime: TimeInterval,
        ofAsset asset: SourceAsset,
        maxPixelSize: CGFloat = 1024
    ) async -> CIImage? {
        let url = SessionPaths.mediaURL(for: asset.fileName)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let aspect = asset.aspectRatio
        generator.maximumSize = aspect >= 1
            ? CGSize(width: maxPixelSize, height: (maxPixelSize / aspect).rounded())
            : CGSize(width: (maxPixelSize * aspect).rounded(), height: maxPixelSize)

        do {
            let requested = CMTime(seconds: max(sourceTime, 0), preferredTimescale: 600)
            let (image, _) = try await generator.image(at: requested)
            return CIImage(cgImage: image)
        } catch {
            FramesLog.render.notice(
                "Frame sample failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// A small image representing the edit, for building filter thumbnails from
    /// one decode instead of one per filter.
    static func representativeImage(
        for document: EditDocument,
        at time: TimeInterval,
        maxPixelSize: CGFloat = 320
    ) async -> CIImage? {
        switch document.kind {
        case .photo:
            guard let asset = document.primaryAsset else { return nil }
            let url = SessionPaths.mediaURL(for: asset.fileName)
            guard let decoded = try? await ImageLoader.shared.image(
                at: url,
                maxPixelSize: Int(maxPixelSize)
            ) else { return nil }
            return CIImage(cgImage: decoded)
        case .video:
            return await frame(at: time, in: document, maxPixelSize: maxPixelSize)
        }
    }
}
