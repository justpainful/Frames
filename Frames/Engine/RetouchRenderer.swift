import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies retouch spots.
///
/// Each spot is a small, soft, local correction composited back through its own
/// feathered mask. Nothing here moves a pixel from one place to another, so no
/// retouch can change the shape of anything — the strongest thing it can do is
/// make a small area look like the area around it.
enum RetouchRenderer {

    static func apply(
        _ spots: [RetouchSpot],
        to image: CIImage,
        quality: RenderQuality
    ) -> CIImage {
        guard !spots.isEmpty else { return image }
        let extent = image.extent
        guard extent.isRenderable else { return image }

        var output = image
        for spot in spots where spot.strength > 0.001 {
            output = apply(spot, to: output, extent: extent, quality: quality)
        }
        return output
    }

    private static func apply(
        _ spot: RetouchSpot,
        to image: CIImage,
        extent: CGRect,
        quality: RenderQuality
    ) -> CIImage {
        guard let mask = softMask(for: spot, extent: extent, strength: spot.strength) else {
            return image
        }

        let corrected: CIImage
        switch spot.kind {
        case .blemish:
            corrected = healed(image, spot: spot, extent: extent, quality: quality)
        case .redEye:
            corrected = redEyeCorrected(image, extent: extent)
        case .brighten:
            corrected = brightened(image, extent: extent)
        }

        return MaskRenderer.blend(effect: corrected, over: image, using: mask, extent: extent)
    }

    // MARK: - Corrections

    /// Replaces a spot with the skin around it.
    ///
    /// A blur wide enough to swallow the blemish would also swallow the skin's
    /// own shading, so the correction keeps the *large-scale* luminance of the
    /// area and takes its colour and fine detail from a heavier blur. That is
    /// what makes a healed spot sit in the surrounding shading instead of
    /// appearing as a flat disc.
    private static func healed(
        _ image: CIImage,
        spot: RetouchSpot,
        extent: CGRect,
        quality: RenderQuality
    ) -> CIImage {
        let shortEdge = min(extent.width, extent.height)
        let radius = Float(max(spot.radius * shortEdge * 0.9 * quality.samplingScale, 1))

        let heavy = CIFilter.gaussianBlur()
        heavy.inputImage = image.clampedToExtent()
        heavy.radius = radius
        guard let replacement = heavy.outputImage?.cropped(to: extent) else { return image }

        let gentle = CIFilter.gaussianBlur()
        gentle.inputImage = image.clampedToExtent()
        gentle.radius = max(radius * 0.25, 0.5)
        guard let shading = gentle.outputImage?.cropped(to: extent) else { return replacement }

        // Colour and texture from the wide blur, luminance from the narrow one,
        // so the patch keeps the shape of the light falling on the skin.
        let combine = CIFilter.luminosityBlendMode()
        combine.backgroundImage = replacement
        combine.inputImage = shading
        return combine.outputImage?.cropped(to: extent) ?? replacement
    }

    /// Pulls the red channel down towards the green and blue, which is exactly
    /// what red-eye is: a red channel far above the others inside the pupil.
    private static func redEyeCorrected(_ image: CIImage, extent: CGRect) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        // Rebuild red as a blend of the other two channels, leaving luminance
        // roughly intact so the pupil stays dark rather than becoming grey mush.
        matrix.rVector = CIVector(x: 0.18, y: 0.5, z: 0.32, w: 0)
        matrix.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let neutralised = matrix.outputImage?.cropped(to: extent) else { return image }

        // A pupil should end up dark and almost colourless.
        let controls = CIFilter.colorControls()
        controls.inputImage = neutralised
        controls.saturation = 0.15
        controls.brightness = -0.03
        controls.contrast = 1.05
        return controls.outputImage?.cropped(to: extent) ?? neutralised
    }

    /// Lifts a small shadow without flattening it.
    private static func brightened(_ image: CIImage, extent: CGRect) -> CIImage {
        let shadows = CIFilter.highlightShadowAdjust()
        shadows.inputImage = image
        shadows.shadowAmount = 0.55
        shadows.highlightAmount = 1
        shadows.radius = 8
        guard let lifted = shadows.outputImage?.cropped(to: extent) else { return image }

        let controls = CIFilter.colorControls()
        controls.inputImage = lifted
        controls.brightness = 0.04
        controls.saturation = 1.02
        controls.contrast = 0.98
        return controls.outputImage?.cropped(to: extent) ?? lifted
    }

    // MARK: - Mask

    /// A soft radial mask: hard enough in the middle to do the work, soft
    /// enough at the edge that the correction has no visible boundary.
    private static func softMask(
        for spot: RetouchSpot,
        extent: CGRect,
        strength: Double
    ) -> CIImage? {
        guard extent.isRenderable else { return nil }
        let centre = CoordinateSpaceConverter.imagePoint(from: spot.position, in: extent.size)
            .applying(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let shortEdge = min(extent.width, extent.height)
        let outer = max(spot.radius * shortEdge, 2)

        let gradient = CIFilter.radialGradient()
        gradient.center = centre
        gradient.radius0 = Float(outer * 0.35)
        gradient.radius1 = Float(outer)
        let level = CGFloat(min(max(strength, 0), 1))
        gradient.color0 = CIColor(red: level, green: level, blue: level, alpha: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        return gradient.outputImage?.cropped(to: extent)
    }
}
