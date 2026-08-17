import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The part that actually removes skin texture.
///
/// The previous attempt failed for a specific, structural reason worth writing
/// down so it is not repeated: it protected "edges" using a detector running at
/// about a third of a percent of the frame's width. At that scale the edges
/// *are* the pores, the freckles, the blemishes and the hairs — so the mask was
/// carefully preserving exactly what it was supposed to remove, and the only
/// visible change left was the colour stages. It read as a colour filter
/// because that is all it was.
///
/// The fix is a scale separation, not a tuning change:
///
/// - **Removing** happens at the scale of the features being removed. A pore is
///   two or three pixels at 1080p, a freckle five to ten, a blemish ten to
///   twenty, a hair two or three across. A blur wide enough to swallow the
///   largest of those swallows all of them.
/// - **Protecting** happens at the scale of the things worth keeping — the lash
///   line, the nostril, the lip edge, the jaw, the hairline. Those are tens of
///   pixels and produce a gradient across that distance. Nothing at pore scale
///   does.
///
/// The algebra also collapses helpfully. Splitting into base, mid and high
/// bands and reassembling with the high band attenuated:
///
///     out = large + (base − large) + k·(source − base)
///         = base + k·(source − base)
///         = mix(base, source, k)
///
/// so the three-band separation reduces to one blur and one mix. Everything
/// coarser than the blur radius survives untouched by construction, which is
/// why the face keeps its shape while its surface goes.
enum SkinSmoother {

    /// The smoothed version of the frame.
    ///
    /// - Parameters:
    ///   - image: the frame, already denoised and exposure-corrected.
    ///   - smoothing: how completely texture goes, 0...1.
    ///   - detail: how much fine detail is kept, 0...1. Shrinks the radius
    ///     rather than mixing the original back, so what survives is real
    ///     detail rather than a ghost of the texture at half strength.
    ///   - hairRemoval: strength of the pass that removes thin dark features —
    ///     stubble, stray hairs, dark specks — before the blur, so they are not
    ///     smeared into grey streaks instead of disappearing.
    static func smoothed(
        _ image: CIImage,
        smoothing: Double,
        detail: Double,
        hairRemoval: Double,
        shortEdge: CGFloat,
        extent: CGRect
    ) -> CIImage {
        guard extent.isRenderable, smoothing > 0.01 else { return image }

        var working = image

        // Thin dark features first. A blur spreads a dark hair into a grey
        // smudge; a small morphological maximum deletes it, because a hair is
        // thinner than the structuring element and every pixel under it has a
        // lighter neighbour within reach. Bounded hard: at a large radius this
        // starts eating eyelashes and nostrils.
        if hairRemoval > 0.01 {
            let radius = Float(max(shortEdge * 0.0016 * hairRemoval, 1))
            let dilate = CIFilter.morphologyMaximum()
            dilate.inputImage = working.clampedToExtent()
            dilate.radius = min(radius, 4)
            if let dilated = dilate.outputImage?.cropped(to: extent) {
                // Partially, and only on luminance: taking the colour from the
                // maximum too would lighten the whole area.
                let recolour = CIFilter.luminosityBlendMode()
                recolour.backgroundImage = working
                recolour.inputImage = dilated
                let lifted = recolour.outputImage?.cropped(to: extent) ?? dilated
                working = mix(working, lifted, amount: min(hairRemoval, 1) * 0.85, extent: extent)
            }
        }

        // The removal scale. At 1080p short edge this is up to about twelve
        // pixels, which is wider than a blemish — the whole point. The detail
        // setting pulls it back towards pore scale.
        let radius = Float(max(shortEdge * 0.011 * (1 - detail * 0.72), 1.5))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = working.clampedToExtent()
        blur.radius = radius
        guard let base = blur.outputImage?.cropped(to: extent) else { return working }

        // mix(base, source, 1 − smoothing). At full smoothing the surface is
        // the blur and nothing coarser than the radius has moved.
        return mix(base, working, amount: 1 - clamp01(smoothing), extent: extent)
    }

    /// Where structure lives, at a scale that only structure reaches.
    ///
    /// A difference of two wide gaussians. The inner one is already wider than
    /// any skin texture, so texture cancels between them and only gradients
    /// that persist across tens of pixels survive — which is the definition of
    /// the features worth protecting.
    static func structureMap(
        of image: CIImage,
        shortEdge: CGFloat,
        extent: CGRect
    ) -> CIImage? {
        guard extent.isRenderable else { return nil }

        let mono = CIFilter.colorControls()
        mono.inputImage = image
        mono.saturation = 0
        mono.brightness = 0
        mono.contrast = 1
        guard let gray = mono.outputImage?.cropped(to: extent) else { return nil }

        let inner = CIFilter.gaussianBlur()
        inner.inputImage = gray.clampedToExtent()
        inner.radius = Float(max(shortEdge * 0.014, 2))

        let outer = CIFilter.gaussianBlur()
        outer.inputImage = gray.clampedToExtent()
        outer.radius = Float(max(shortEdge * 0.055, 6))

        guard let near = inner.outputImage?.cropped(to: extent),
              let far = outer.outputImage?.cropped(to: extent)
        else { return nil }

        let difference = CIFilter.differenceBlendMode()
        difference.inputImage = near
        difference.backgroundImage = far
        guard let raw = difference.outputImage?.cropped(to: extent) else { return nil }

        // Steepen into a decision and widen it a little, so the protected band
        // covers the feature rather than a hairline along its centre.
        let gain = CIFilter.colorPolynomial()
        gain.inputImage = raw
        let coefficients = CIVector(x: -0.04, y: 9.0, z: 0, w: 0)
        gain.redCoefficients = coefficients
        gain.greenCoefficients = coefficients
        gain.blueCoefficients = coefficients
        guard let steep = gain.outputImage else { return nil }

        let spread = CIFilter.gaussianBlur()
        spread.inputImage = clamped(steep, extent: extent).clampedToExtent()
        spread.radius = Float(max(shortEdge * 0.008, 2))
        guard let widened = spread.outputImage?.cropped(to: extent) else { return nil }

        return clamped(widened, extent: extent)
    }

    // MARK: - Helpers

    /// `amount` of `top` over `bottom`, uniformly.
    static func mix(
        _ bottom: CIImage,
        _ top: CIImage,
        amount: Double,
        extent: CGRect
    ) -> CIImage {
        let value = clamp01(amount)
        if value <= 0.001 { return bottom }
        if value >= 0.999 { return top }

        let level = CGFloat(value)
        let mask = CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: extent)
        return MaskRenderer.blend(effect: top, over: bottom, using: mask, extent: extent)
    }

    static func clamped(_ image: CIImage, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    // MARK: - Working resolution

    /// Spatial work is done small and the result is scaled back up.
    ///
    /// Every stage here is low-frequency by definition — a blur, a mask, a
    /// difference of blurs — so computing it at a quarter of the pixels and
    /// enlarging is visually identical and roughly four times cheaper. This is
    /// the single biggest reason the capture path can hold its frame rate
    /// instead of heating the phone.
    static func workingScale(for extent: CGRect, target: CGFloat = 720) -> CGFloat {
        let longEdge = max(extent.width, extent.height)
        guard longEdge > target else { return 1 }
        return target / longEdge
    }

    static func downscaled(_ image: CIImage, scale: CGFloat) -> CIImage {
        guard scale < 0.999 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    static func upscaled(_ image: CIImage, scale: CGFloat, to extent: CGRect) -> CIImage {
        guard scale < 0.999 else { return image }
        let factor = 1 / scale
        return image
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .cropped(to: extent)
    }
}
