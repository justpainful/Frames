import CoreGraphics
import CoreImage
import Foundation

/// Everything a single frame needs beyond the document itself.
///
/// Resolving these outside the composer is what keeps the composer synchronous
/// and pure — it can therefore run inside an `AVVideoCompositing` callback, on
/// a background queue, or on the main actor for a still, with identical results.
struct FrameResources {
    var detections: DetectionContext = .empty
    var overlays: OverlayResources = .empty
    /// The image used when `BackgroundStyle.fill` is `.image`.
    var backgroundImage: CIImage?

    static let empty = FrameResources()
}

/// Turns a source frame plus an `EditDocument` into the finished picture.
///
/// This function is the contract between the preview and the export: both call
/// it with the same document, so anything the user can see on screen is by
/// construction what ends up in the file. There is no second implementation of
/// any visible effect.
enum FrameComposer {

    /// The order stages run in, and why:
    ///
    /// 1. **Geometry** — crop, straighten, flip. Everything after this sees the
    ///    frame the user composed, so a vignette hugs the cropped edges.
    /// 2. **Grade** — filter, then adjustments. The filter is the base look;
    ///    the user's own adjustments sit on top of it, which is the order they
    ///    expect when they nudge exposure after picking a filter.
    /// 3. **Selective adjustments** — masked grading, over the global grade.
    /// 4. **Effects** — texture and motion, applied to the graded picture.
    /// 5. **Blur** — last of the pixel stages, so blurring a face actually
    ///    hides it rather than hiding a version of it that a later sharpen
    ///    brings back.
    /// 6. **Fit** — place the content in the output frame and fill the rest.
    /// 7. **Overlays** — text, images and drawings sit on top of everything,
    ///    unblurred and ungraded, because they are the user's annotations, not
    ///    part of the photograph.
    static func compose(
        source: CIImage,
        document: EditDocument,
        clip: VideoClip?,
        time: TimeInterval,
        outputSize: CGSize,
        resources: FrameResources,
        quality: RenderQuality
    ) -> CIImage {
        let signpost = FramesLog.signposter.beginInterval("composeFrame")
        defer { FramesLog.signposter.endInterval("composeFrame", signpost) }

        var image = source
        guard image.extent.isRenderable else { return image }

        // 1. Geometry
        let crop = clip?.crop ?? document.photo?.crop ?? .identity
        image = GeometryRenderer.applyCrop(crop, to: image)

        // 2. Grade
        image = FilterRenderer.apply(document.grade.filter, to: image, quality: quality)
        image = AdjustmentRenderer.apply(document.grade.adjustments, to: image, quality: quality)

        // 3. Selective adjustments
        image = applySelectiveAdjustments(
            document.selectiveAdjustments,
            to: image,
            time: time,
            detections: resources.detections,
            quality: quality
        )

        // 4. Effects
        image = EffectRenderer.apply(document.effects, to: image, time: time, quality: quality)

        // 5. Blur
        image = BlurRenderer.apply(
            document.blurRegions,
            to: image,
            time: time,
            detections: resources.detections,
            quality: quality
        )

        // 6. Fit into the output frame
        let clipTransform = clip?.transform ?? document.photo?.transform ?? .identity
        if !clipTransform.isIdentity {
            image = GeometryRenderer.applyTransform(
                clipTransform,
                to: image,
                outputRect: CGRect(origin: .zero, size: outputSize)
            )
        }
        image = GeometryRenderer.fit(
            content: image,
            into: outputSize,
            background: document.background,
            backgroundImage: resources.backgroundImage,
            quality: quality
        )

        // 7. Overlays
        image = OverlayCompositor.composite(
            document: document,
            onto: image,
            time: time,
            resources: resources.overlays,
            quality: quality
        )

        return image.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// Renders the original media with no edits applied, for the before/after
    /// comparison. Geometry still applies — comparing a cropped edit against an
    /// uncropped original would just look like a bug.
    static func composeOriginal(
        source: CIImage,
        document: EditDocument,
        clip: VideoClip?,
        outputSize: CGSize,
        quality: RenderQuality
    ) -> CIImage {
        var image = source
        guard image.extent.isRenderable else { return image }
        let crop = clip?.crop ?? document.photo?.crop ?? .identity
        image = GeometryRenderer.applyCrop(crop, to: image)
        image = GeometryRenderer.fit(
            content: image,
            into: outputSize,
            background: document.background,
            backgroundImage: nil,
            quality: quality
        )
        return image.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private static func applySelectiveAdjustments(
        _ adjustments: [SelectiveAdjustment],
        to image: CIImage,
        time: TimeInterval,
        detections: DetectionContext,
        quality: RenderQuality
    ) -> CIImage {
        guard !adjustments.isEmpty else { return image }
        let extent = image.extent
        var output = image

        for adjustment in adjustments where adjustment.isActive {
            if let range = adjustment.timeRange, !range.contains(time) { continue }
            guard let mask = MaskRenderer.mask(
                for: adjustment.mask,
                extent: extent,
                time: time,
                detections: detections,
                quality: quality
            ) else { continue }

            let adjusted = AdjustmentRenderer.apply(adjustment.adjustments, to: output, quality: quality)
            output = MaskRenderer.blend(effect: adjusted, over: output, using: mask, extent: extent)
        }
        return output
    }

    /// What the frame needs from Vision, so the caller runs exactly that.
    static func detectionRequirements(for document: EditDocument) -> DetectionRequirements {
        var requirements = BlurRenderer.detectionRequirements(for: document.blurRegions)
        for adjustment in document.selectiveAdjustments {
            switch adjustment.mask.shape {
            case .face: requirements.needsFaces = true
            case .person: requirements.needsPersonInstances = true
            case .foregroundSubject: requirements.needsSubject = true
            default: break
            }
            if let id = adjustment.mask.trackedObjectID {
                requirements.trackedObjectIDs.insert(id)
            }
        }
        return requirements
    }

    /// A cheap value that changes whenever anything visible changes.
    ///
    /// The preview uses it to decide whether a re-render is needed at all,
    /// which is what keeps scrubbing from re-running the whole chain for frames
    /// whose edit has not moved.
    static func visualSignature(of document: EditDocument, at time: TimeInterval) -> Int {
        var hasher = Hasher()
        hasher.combine(document.grade)
        hasher.combine(document.effects)
        hasher.combine(document.blurRegions)
        hasher.combine(document.selectiveAdjustments)
        hasher.combine(document.textOverlays)
        hasher.combine(document.imageOverlays)
        hasher.combine(document.drawings)
        hasher.combine(document.background)
        hasher.combine(document.outputAspect)
        hasher.combine(document.photo)
        hasher.combine(document.videoTrack)
        // Quantised so a sub-frame scrub does not invalidate the cache.
        hasher.combine(Int((time * 60).rounded()))
        return hasher.finalize()
    }
}
