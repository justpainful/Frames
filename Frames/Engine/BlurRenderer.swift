import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies blur regions.
///
/// The six blur scopes the user sees are one operation with different masks:
/// blur the whole frame, then composite the blurred version back through the
/// mask the scope produced. That is why a face blur, an area blur and a
/// background blur all behave identically under keyframing, tracking and
/// export.
enum BlurRenderer {

    static func apply(
        _ regions: [BlurRegion],
        to image: CIImage,
        time: TimeInterval,
        detections: DetectionContext,
        quality: RenderQuality
    ) -> CIImage {
        guard !regions.isEmpty else { return image }
        var output = image
        let extent = image.extent
        guard extent.isRenderable else { return image }

        for region in regions where region.isActive(at: time) {
            let strength = region.strength(at: time)
            guard strength > 0.001 else { continue }

            let blurred = blurredImage(
                from: output,
                style: region.style,
                strength: strength,
                extent: extent,
                quality: quality
            )

            guard let definition = region.mask else {
                // Full-frame blur: nothing to composite through.
                output = blurred
                continue
            }

            guard let mask = MaskRenderer.mask(
                for: definition,
                extent: extent,
                time: time,
                detections: detections,
                quality: quality
            ) else { continue }

            // `invertsSubject` is what makes "blur the background" and "blur
            // this person" the same code path.
            let resolvedMask = region.invertsSubject ? invert(mask, extent: extent) : mask
            output = MaskRenderer.blend(effect: blurred, over: output, using: resolvedMask, extent: extent)
        }

        return output
    }

    /// Produces the blurred version of a whole frame.
    static func blurredImage(
        from image: CIImage,
        style: BlurStyle,
        strength: Double,
        extent: CGRect,
        quality: RenderQuality
    ) -> CIImage {
        let shortEdge = min(extent.width, extent.height)
        let scale = quality.samplingScale

        switch style {
        case .gaussian:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(strength * shortEdge * 0.09 * scale)
            return filter.outputImage?.cropped(to: extent) ?? image

        case .box:
            let filter = CIFilter.boxBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(strength * shortEdge * 0.08 * scale)
            return filter.outputImage?.cropped(to: extent) ?? image

        case .disc:
            let filter = CIFilter.discBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(strength * shortEdge * 0.06 * scale)
            return filter.outputImage?.cropped(to: extent) ?? image

        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            // A visible minimum: a one-pixel "pixelation" is not redaction.
            filter.scale = Float(max(strength * shortEdge * 0.06, 4))
            return filter.outputImage?.cropped(to: extent) ?? image

        case .mosaic:
            let filter = CIFilter.hexagonalPixellate()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.scale = Float(max(strength * shortEdge * 0.05, 4))
            return filter.outputImage?.cropped(to: extent) ?? image
        }
    }

    private static func invert(_ mask: CIImage, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorInvert()
        filter.inputImage = mask
        return filter.outputImage?.cropped(to: extent) ?? mask
    }

    /// Which Vision work a set of blur regions needs, so the frame provider can
    /// run exactly that and no more.
    static func detectionRequirements(for regions: [BlurRegion]) -> DetectionRequirements {
        var requirements = DetectionRequirements()
        for region in regions {
            switch region.scope {
            case .face: requirements.needsFaces = true
            case .person: requirements.needsPersonInstances = true
            case .background: requirements.needsSubject = true
            case .track:
                if let id = region.mask?.trackedObjectID { requirements.trackedObjectIDs.insert(id) }
            case .full, .area: break
            }
        }
        return requirements
    }
}

/// What a frame needs from Vision.
struct DetectionRequirements: Hashable, Sendable {
    var needsFaces = false
    var needsPersonInstances = false
    var needsSubject = false
    var trackedObjectIDs: Set<UUID> = []

    var isEmpty: Bool {
        !needsFaces && !needsPersonInstances && !needsSubject && trackedObjectIDs.isEmpty
    }

    static func + (lhs: DetectionRequirements, rhs: DetectionRequirements) -> DetectionRequirements {
        DetectionRequirements(
            needsFaces: lhs.needsFaces || rhs.needsFaces,
            needsPersonInstances: lhs.needsPersonInstances || rhs.needsPersonInstances,
            needsSubject: lhs.needsSubject || rhs.needsSubject,
            trackedObjectIDs: lhs.trackedObjectIDs.union(rhs.trackedObjectIDs)
        )
    }
}
