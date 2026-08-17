import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Turns an `AdjustmentSet` into Core Image operations.
///
/// This is the only implementation of what the Adjust tool means. The photo
/// preview, the video preview, the still export and the video export all call
/// it, which is why a slider can never behave differently in the export than it
/// did on screen.
///
/// Parameter values arrive normalized (see `AdjustmentParameter.range`) and are
/// mapped here onto the filter inputs they drive. The mappings are deliberately
/// gentle: at full deflection an adjustment should look strong, not broken.
enum AdjustmentRenderer {

    static func apply(_ set: AdjustmentSet, to image: CIImage, quality: RenderQuality) -> CIImage {
        guard !set.isIdentity else { return image }
        var output = image

        output = applyLight(set, to: output)
        output = applyColor(set, to: output)
        output = applyDetail(set, to: output, quality: quality)
        output = applyFinishing(set, to: output, quality: quality)

        return output
    }

    // MARK: - Light

    private static func applyLight(_ set: AdjustmentSet, to image: CIImage) -> CIImage {
        var output = image

        if set.isActive(.exposure) {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            // ±2 stops at full deflection: enough to rescue a dark frame,
            // not enough to destroy one by accident.
            filter.ev = Float(set[.exposure] * 2)
            output = filter.outputImage ?? output
        }

        if set.isActive(.highlights) || set.isActive(.shadows) {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = output
            // Core Image's highlight input is 1 = untouched, 0 = fully pulled
            // down; shadow is 0 = untouched, 1 = fully lifted.
            filter.highlightAmount = Float(1 + set[.highlights] * 0.75)
            filter.shadowAmount = Float(set[.shadows] * 0.9)
            filter.radius = 12
            output = filter.outputImage ?? output
        }

        if set.isActive(.brilliance) {
            // Brilliance is local contrast plus a gentle shadow lift: it makes
            // a flat frame read as brighter without blowing the highlights.
            let amount = set[.brilliance]
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = output
            unsharp.radius = 40
            unsharp.intensity = Float(amount * 0.5)
            output = unsharp.outputImage ?? output

            if amount > 0 {
                let shadows = CIFilter.highlightShadowAdjust()
                shadows.inputImage = output
                shadows.shadowAmount = Float(amount * 0.35)
                shadows.highlightAmount = Float(1 - amount * 0.2)
                output = shadows.outputImage ?? output
            }
        }

        if set.isActive(.brightness) || set.isActive(.contrast) {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = Float(set[.brightness] * 0.28)
            filter.contrast = Float(1 + set[.contrast] * 0.5)
            filter.saturation = 1
            output = filter.outputImage ?? output
        }

        if set.isActive(.blackPoint) {
            // Positive crushes the blacks, negative lifts them.
            let amount = set[.blackPoint]
            let filter = CIFilter.colorPolynomial()
            filter.inputImage = output
            let lift = Float(-amount * 0.12)
            let gain = Float(1 + amount * 0.16)
            let vector = CIVector(x: CGFloat(lift), y: CGFloat(gain), z: 0, w: 0)
            filter.redCoefficients = vector
            filter.greenCoefficients = vector
            filter.blueCoefficients = vector
            output = filter.outputImage ?? output
        }

        return output
    }

    // MARK: - Color

    private static func applyColor(_ set: AdjustmentSet, to image: CIImage) -> CIImage {
        var output = image

        if set.isActive(.saturation) {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.contrast = 1
            filter.saturation = Float(1 + set[.saturation])
            output = filter.outputImage ?? output
        }

        if set.isActive(.vibrance) {
            let filter = CIFilter.vibrance()
            filter.inputImage = output
            filter.amount = Float(set[.vibrance])
            output = filter.outputImage ?? output
        }

        if set.isActive(.warmth) || set.isActive(.tint) {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            // Neutral stays at D65; the target moves, which is what shifts the
            // image. Positive warmth pushes towards tungsten.
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(
                x: CGFloat(6500 - set[.warmth] * 2200),
                y: CGFloat(set[.tint] * 60)
            )
            output = filter.outputImage ?? output
        }

        return output
    }

    // MARK: - Detail

    private static func applyDetail(_ set: AdjustmentSet, to image: CIImage, quality: RenderQuality) -> CIImage {
        var output = image

        if set.isActive(.noiseReduction) || set.isActive(.smoothness) {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = output
            filter.noiseLevel = Float(0.01 + set[.noiseReduction] * 0.06 + set[.smoothness] * 0.04)
            filter.sharpness = Float(max(0, 0.4 - set[.smoothness] * 0.4))
            output = filter.outputImage ?? output
        }

        if set.isActive(.definition) {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = output
            filter.radius = 12
            filter.intensity = Float(set[.definition] * 1.2)
            output = filter.outputImage ?? output
        }

        if set.isActive(.sharpness) {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = output
            filter.sharpness = Float(set[.sharpness] * 1.4)
            filter.radius = 2
            output = filter.outputImage ?? output
        }

        if set.isActive(.grain), quality.appliesExpensiveStages {
            output = GrainRenderer.apply(amount: set[.grain], to: output)
        }

        return output
    }

    // MARK: - Finishing

    private static func applyFinishing(_ set: AdjustmentSet, to image: CIImage, quality: RenderQuality) -> CIImage {
        var output = image

        if set.isActive(.fade) {
            // Fade lifts the blacks and pulls contrast: the matte-print look.
            let amount = set[.fade]
            let filter = CIFilter.colorPolynomial()
            filter.inputImage = output
            let lift = CGFloat(amount * 0.13)
            let gain = CGFloat(1 - amount * 0.22)
            let vector = CIVector(x: lift, y: gain, z: 0, w: 0)
            filter.redCoefficients = vector
            filter.greenCoefficients = vector
            filter.blueCoefficients = vector
            output = filter.outputImage ?? output
        }

        if set.isActive(.vignette) {
            let filter = CIFilter.vignette()
            filter.inputImage = output
            filter.intensity = Float(set[.vignette] * 1.6)
            filter.radius = 1.6
            output = filter.outputImage ?? output
        }

        return output
    }
}

/// Film grain, kept separate because both the Adjust tool and the Grain effect
/// want exactly the same thing.
enum GrainRenderer {
    /// A single noise image, generated once. `CIRandomGenerator` produces an
    /// infinite image, so this costs nothing to keep around and saves
    /// regenerating noise for every frame.
    private static let noise: CIImage = {
        let generator = CIFilter.randomGenerator()
        let base = generator.outputImage ?? CIImage(color: .gray)
        // Desaturate: coloured noise reads as a broken sensor, not as film.
        let mono = CIFilter.colorMatrix()
        mono.inputImage = base
        mono.rVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
        mono.gVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
        mono.bVector = CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return mono.outputImage ?? base
    }()

    static func apply(amount: Double, to image: CIImage, seed: Double = 0) -> CIImage {
        guard amount > 0.001 else { return image }

        let extent = image.extent
        guard extent.isRenderable else { return image }

        // Offsetting the noise per frame keeps video grain alive rather than
        // looking like dirt on the lens.
        let offset = CGAffineTransform(translationX: CGFloat(seed * 137).truncatingRemainder(dividingBy: 512),
                                       y: CGFloat(seed * 311).truncatingRemainder(dividingBy: 512))
        let grain = noise.transformed(by: offset).cropped(to: extent)

        let fade = CIFilter.colorMatrix()
        fade.inputImage = grain
        let strength = CGFloat(amount * 0.28)
        fade.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        fade.gVector = CIVector(x: 0, y: strength, z: 0, w: 0)
        fade.bVector = CIVector(x: 0, y: 0, z: strength, w: 0)
        fade.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        fade.biasVector = CIVector(x: 0.5 - strength / 2, y: 0.5 - strength / 2, z: 0.5 - strength / 2, w: 1)

        let blend = CIFilter.overlayBlendMode()
        blend.backgroundImage = image
        blend.inputImage = fade.outputImage ?? grain
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
