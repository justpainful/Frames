import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies a `FilterRecipe` to an image.
///
/// Filters are recipes of primitives, not baked lookup tables. Intensity is a
/// real interpolation of the recipe's parameters rather than a cross-fade
/// between two rendered images, which means a filter at 40% composes correctly
/// with the user's own adjustments instead of fighting them.
enum FilterRenderer {

    static func apply(_ instance: FilterInstance?, to image: CIImage, quality: RenderQuality) -> CIImage {
        guard let instance, instance.intensity > 0.001,
              let preset = instance.preset, !preset.recipe.isNeutral
        else { return image }
        return apply(preset.recipe, intensity: instance.intensity, to: image, quality: quality)
    }

    static func apply(
        _ recipe: FilterRecipe,
        intensity: Double,
        to image: CIImage,
        quality: RenderQuality
    ) -> CIImage {
        let strength = min(max(intensity, 0), 1)
        guard strength > 0.001 else { return image }
        var output = image

        if recipe.isMonochrome {
            output = monochrome(output, amount: strength)
        }

        output = AdjustmentRenderer.apply(
            recipe.adjustments.scaled(by: strength),
            to: output,
            quality: quality
        )

        output = applyToneCurve(recipe.toneCurve, amount: strength, to: output)
        output = applyChannelShaping(recipe, amount: strength, to: output)
        output = applySplitTone(recipe, amount: strength, to: output)

        if recipe.bloom > 0.001, quality.appliesExpensiveStages {
            let bloom = CIFilter.bloom()
            bloom.inputImage = output
            bloom.intensity = Float(recipe.bloom * strength)
            bloom.radius = Float(12 * quality.samplingScale)
            output = bloom.outputImage?.cropped(to: image.extent) ?? output
        }

        return output
    }

    // MARK: - Stages

    private static func monochrome(_ image: CIImage, amount: Double) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.brightness = 0
        filter.contrast = 1
        filter.saturation = Float(1 - amount)
        return filter.outputImage ?? image
    }

    /// Five control points, evaluated by Core Image as a spline. Interpolating
    /// each point towards the identity curve is what makes intensity behave.
    private static func applyToneCurve(_ points: [Double], amount: Double, to image: CIImage) -> CIImage {
        guard points.count == 5 else { return image }
        let identity: [Double] = [0, 0.25, 0.5, 0.75, 1]
        guard zip(points, identity).contains(where: { abs($0 - $1) > 0.001 }) else { return image }

        let blended = zip(points, identity).map { point, base in
            base + (point - base) * amount
        }

        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0, y: blended[0])
        filter.point1 = CGPoint(x: 0.25, y: blended[1])
        filter.point2 = CGPoint(x: 0.5, y: blended[2])
        filter.point3 = CGPoint(x: 0.75, y: blended[3])
        filter.point4 = CGPoint(x: 1, y: blended[4])
        return filter.outputImage ?? image
    }

    /// Per-channel gain and lift, which is how a grade gets its colour cast.
    private static func applyChannelShaping(
        _ recipe: FilterRecipe,
        amount: Double,
        to image: CIImage
    ) -> CIImage {
        let gain = recipe.channelGain
        let lift = recipe.channelLift
        let isNeutral = abs(gain.red - 1) < 0.001 && abs(gain.green - 1) < 0.001
            && abs(gain.blue - 1) < 0.001 && abs(lift.red) < 0.001
            && abs(lift.green) < 0.001 && abs(lift.blue) < 0.001
        guard !isNeutral else { return image }

        func blend(_ value: Double, towards identity: Double) -> CGFloat {
            CGFloat(identity + (value - identity) * amount)
        }

        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: blend(gain.red, towards: 1), y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: blend(gain.green, towards: 1), z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: blend(gain.blue, towards: 1), w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(
            x: blend(lift.red, towards: 0),
            y: blend(lift.green, towards: 0),
            z: blend(lift.blue, towards: 0),
            w: 0
        )
        return filter.outputImage ?? image
    }

    /// Colour pushed into the shadows and highlights independently.
    ///
    /// Expressed as a per-channel polynomial so it costs one pass:
    /// the shadow term is `s·(1−c)²`, which expands to `s − 2s·c + s·c²`, and
    /// the highlight term is `h·c²`. Both fall off exactly where they should,
    /// with no mask and no second render.
    private static func applySplitTone(
        _ recipe: FilterRecipe,
        amount: Double,
        to image: CIImage
    ) -> CIImage {
        let strength = recipe.splitToneStrength * amount
        guard strength > 0.001 else { return image }

        let shadow = recipe.shadowTint
        let highlight = recipe.highlightTint

        func coefficients(shadowAmount: Double, highlightAmount: Double) -> CIVector {
            let s = shadowAmount * strength
            let h = highlightAmount * strength
            return CIVector(
                x: CGFloat(s),
                y: CGFloat(1 - 2 * s),
                z: CGFloat(s + h),
                w: 0
            )
        }

        let filter = CIFilter.colorPolynomial()
        filter.inputImage = image
        filter.redCoefficients = coefficients(shadowAmount: shadow.red, highlightAmount: highlight.red)
        filter.greenCoefficients = coefficients(shadowAmount: shadow.green, highlightAmount: highlight.green)
        filter.blueCoefficients = coefficients(shadowAmount: shadow.blue, highlightAmount: highlight.blue)
        return filter.outputImage ?? image
    }

    // MARK: - Thumbnails

    /// Renders a small preview of a filter for the filter strip.
    ///
    /// The thumbnails all start from one downsampled source image, so building
    /// the whole strip costs one decode rather than twenty-four.
    static func thumbnail(
        of preset: FilterPreset,
        from source: CIImage,
        context: CIContext,
        size: CGSize
    ) -> CGImage? {
        let graded = apply(preset.recipe, intensity: 1, to: source, quality: .interactive)
        let rect = CGRect(origin: .zero, size: size)
        let scaleX = size.width / max(source.extent.width, 1)
        let scaleY = size.height / max(source.extent.height, 1)
        let scale = max(scaleX, scaleY)
        let scaled = graded.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: rect)
    }
}
