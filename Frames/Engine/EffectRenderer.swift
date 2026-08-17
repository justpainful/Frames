import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies the effects catalogue.
///
/// Every case in `EffectKind` is implemented here. Temporal effects take the
/// frame time so a video shakes and leaks light over time while a still gets a
/// fixed, sensible sample of the same effect — one implementation, both media
/// types, identical in preview and export.
enum EffectRenderer {

    static func apply(
        _ effects: [EffectInstance],
        to image: CIImage,
        time: TimeInterval,
        quality: RenderQuality
    ) -> CIImage {
        guard !effects.isEmpty else { return image }
        var output = image
        for effect in effects where effect.isActive(at: time) {
            let intensity = effect.intensity(at: time)
            guard intensity > 0.001 else { continue }
            output = apply(effect.kind, intensity: intensity, to: output, time: time, quality: quality)
        }
        return output
    }

    static func apply(
        _ kind: EffectKind,
        intensity: Double,
        to image: CIImage,
        time: TimeInterval,
        quality: RenderQuality
    ) -> CIImage {
        let extent = image.extent
        guard extent.isRenderable else { return image }
        let shortEdge = min(extent.width, extent.height)
        let scale = quality.samplingScale

        switch kind {
        case .bloom:
            let filter = CIFilter.bloom()
            filter.inputImage = image
            filter.intensity = Float(intensity)
            filter.radius = Float(max(intensity * shortEdge * 0.02 * scale, 1))
            return filter.outputImage?.cropped(to: extent) ?? image

        case .glow:
            // Bloom plus a soft screen pass reads as light spilling out of the
            // highlights rather than as a blur.
            let bloom = CIFilter.bloom()
            bloom.inputImage = image
            bloom.intensity = Float(intensity * 0.8)
            bloom.radius = Float(max(intensity * shortEdge * 0.03 * scale, 1))
            let bloomed = bloom.outputImage?.cropped(to: extent) ?? image

            let blur = CIFilter.gaussianBlur()
            blur.inputImage = bloomed.clampedToExtent()
            blur.radius = Float(max(intensity * shortEdge * 0.02 * scale, 1))
            let soft = blur.outputImage?.cropped(to: extent) ?? bloomed

            let screen = CIFilter.screenBlendMode()
            screen.backgroundImage = image
            screen.inputImage = fade(soft, to: intensity * 0.5, extent: extent)
            return screen.outputImage?.cropped(to: extent) ?? bloomed

        case .softBlur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(max(intensity * shortEdge * 0.015 * scale, 0.5))
            return filter.outputImage?.cropped(to: extent) ?? image

        case .sharpen:
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(max(shortEdge * 0.004, 1))
            filter.intensity = Float(intensity * 1.6)
            return filter.outputImage?.cropped(to: extent) ?? image

        case .motionBlur:
            let filter = CIFilter.motionBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(max(intensity * shortEdge * 0.02 * scale, 1))
            // Slowly rotating angle keeps a still from looking like a mistake
            // and gives video a sense of direction.
            filter.angle = Float(sin(time * 0.7) * 0.6)
            return filter.outputImage?.cropped(to: extent) ?? image

        case .shake:
            // Deterministic pseudo-random displacement: the same time always
            // produces the same offset, so preview and export match frame for
            // frame.
            let amplitude = intensity * shortEdge * 0.012
            let dx = CGFloat(sin(time * 37.1) * 0.6 + sin(time * 11.3) * 0.4) * CGFloat(amplitude)
            let dy = CGFloat(cos(time * 29.7) * 0.6 + cos(time * 13.9) * 0.4) * CGFloat(amplitude)
            return image
                .clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: extent)

        case .zoom:
            let pulse = 1 + intensity * 0.08 * (0.5 + 0.5 * sin(time * 1.9))
            let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .scaledBy(x: CGFloat(pulse), y: CGFloat(pulse))
                .translatedBy(x: -extent.midX, y: -extent.midY)
            return image.clampedToExtent().transformed(by: transform).cropped(to: extent)

        case .grain:
            return GrainRenderer.apply(amount: intensity, to: image, seed: time * 24)

        case .lightLeak:
            return lightLeak(image, intensity: intensity, time: time, extent: extent)

        case .fadedFilm:
            var output = AdjustmentRenderer.apply(
                AdjustmentSet([
                    .fade: intensity * 0.6,
                    .saturation: -intensity * 0.35,
                    .contrast: -intensity * 0.2
                ]),
                to: image,
                quality: quality
            )
            output = GrainRenderer.apply(amount: intensity * 0.4, to: output, seed: time * 24)
            return output

        case .vhs:
            return vhs(image, intensity: intensity, time: time, extent: extent, quality: quality)

        case .scanlines:
            return scanlines(image, intensity: intensity, extent: extent)

        case .chromaticShift:
            return chromaticShift(image, intensity: intensity, extent: extent)

        case .dream:
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(max(intensity * shortEdge * 0.02 * scale, 1))
            let soft = blur.outputImage?.cropped(to: extent) ?? image

            let screen = CIFilter.screenBlendMode()
            screen.backgroundImage = image
            screen.inputImage = fade(soft, to: intensity * 0.7, extent: extent)
            let glowing = screen.outputImage?.cropped(to: extent) ?? image

            return AdjustmentRenderer.apply(
                AdjustmentSet([.fade: intensity * 0.25, .vibrance: intensity * 0.3]),
                to: glowing,
                quality: quality
            )

        case .softLight:
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(max(intensity * shortEdge * 0.03 * scale, 1))
            let soft = blur.outputImage?.cropped(to: extent) ?? image

            let blend = CIFilter.softLightBlendMode()
            blend.backgroundImage = image
            blend.inputImage = fade(soft, to: intensity, extent: extent)
            return blend.outputImage?.cropped(to: extent) ?? image
        }
    }

    // MARK: - Compound effects

    private static func lightLeak(
        _ image: CIImage,
        intensity: Double,
        time: TimeInterval,
        extent: CGRect
    ) -> CIImage {
        // A warm gradient that drifts across the frame, screened on top.
        let drift = CGFloat(0.5 + 0.5 * sin(time * 0.35))
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(
            x: extent.minX + extent.width * (0.15 + drift * 0.7),
            y: extent.minY + extent.height * (0.75 - drift * 0.2)
        )
        gradient.radius0 = 0
        gradient.radius1 = Float(max(extent.width, extent.height) * 0.7)
        gradient.color0 = CIColor(red: 1.0, green: 0.55, blue: 0.2, alpha: CGFloat(intensity * 0.7))
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let leak = gradient.outputImage?.cropped(to: extent) else { return image }
        let screen = CIFilter.screenBlendMode()
        screen.backgroundImage = image
        screen.inputImage = leak
        return screen.outputImage?.cropped(to: extent) ?? image
    }

    private static func vhs(
        _ image: CIImage,
        intensity: Double,
        time: TimeInterval,
        extent: CGRect,
        quality: RenderQuality
    ) -> CIImage {
        var output = chromaticShift(image, intensity: intensity * 0.8, extent: extent)
        output = scanlines(output, intensity: intensity * 0.6, extent: extent)

        // Tracking wobble: a horizontal displacement that varies down the frame.
        let wobble = CGFloat(sin(time * 3.1) * intensity * extent.width * 0.004)
        output = output
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: wobble, y: 0))
            .cropped(to: extent)

        output = AdjustmentRenderer.apply(
            AdjustmentSet([.saturation: intensity * 0.3, .contrast: -intensity * 0.15]),
            to: output,
            quality: quality
        )
        return GrainRenderer.apply(amount: intensity * 0.3, to: output, seed: time * 24)
    }

    private static func scanlines(_ image: CIImage, intensity: Double, extent: CGRect) -> CIImage {
        let stripes = CIFilter.stripesGenerator()
        stripes.center = CGPoint(x: extent.midX, y: extent.midY)
        stripes.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(intensity * 0.35))
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        stripes.width = Float(max(extent.height / 320, 1))
        stripes.sharpness = 1

        guard let lines = stripes.outputImage?
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
            .cropped(to: extent)
        else { return image }

        let over = CIFilter.sourceOverCompositing()
        over.inputImage = lines
        over.backgroundImage = image
        return over.outputImage?.cropped(to: extent) ?? image
    }

    private static func chromaticShift(_ image: CIImage, intensity: Double, extent: CGRect) -> CIImage {
        let offset = CGFloat(intensity * extent.width * 0.004)
        guard offset > 0.25 else { return image }

        func channel(_ source: CIImage, keep: (r: CGFloat, g: CGFloat, b: CGFloat), dx: CGFloat) -> CIImage {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = source.transformed(by: CGAffineTransform(translationX: dx, y: 0))
            matrix.rVector = CIVector(x: keep.r, y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: keep.g, z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: keep.b, w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return matrix.outputImage ?? source
        }

        let clamped = image.clampedToExtent()
        let red = channel(clamped, keep: (1, 0, 0), dx: -offset)
        let green = channel(clamped, keep: (0, 1, 0), dx: 0)
        let blue = channel(clamped, keep: (0, 0, 1), dx: offset)

        let firstBlend = CIFilter.additionCompositing()
        firstBlend.inputImage = red
        firstBlend.backgroundImage = green
        let secondBlend = CIFilter.additionCompositing()
        secondBlend.inputImage = blue
        secondBlend.backgroundImage = firstBlend.outputImage ?? green

        return secondBlend.outputImage?.cropped(to: extent) ?? image
    }

    /// Scales an image's alpha, used to mix an effect layer at partial strength.
    private static func fade(_ image: CIImage, to amount: Double, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(max(amount, 0), 1)))
        return filter.outputImage?.cropped(to: extent) ?? image
    }
}
