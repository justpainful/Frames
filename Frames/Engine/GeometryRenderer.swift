import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Crop, straighten, flip, and fitting content into the output frame.
///
/// Geometry runs before colour so every later stage sees the frame the user
/// actually composed, and so a vignette lands on the cropped edges rather than
/// the original ones.
enum GeometryRenderer {

    /// Applies a crop, its quarter turns, straightening and flips.
    ///
    /// Straightening rotates first and then crops, which is the only order that
    /// avoids the rotated corners appearing inside the result.
    static func applyCrop(_ crop: CropState, to image: CIImage) -> CIImage {
        var state = crop
        state.normalize()
        guard !state.isIdentity else { return image }

        var output = image
        var extent = output.extent
        guard extent.isRenderable else { return image }

        if abs(state.straightenAngle) > 0.0001 {
            let centre = CGPoint(x: extent.midX, y: extent.midY)
            let rotation = CGAffineTransform(translationX: centre.x, y: centre.y)
                .rotated(by: CGFloat(-state.straightenAngle))
                .translatedBy(x: -centre.x, y: -centre.y)
            output = output.clampedToExtent().transformed(by: rotation).cropped(to: extent)
        }

        if state.flipHorizontal || state.flipVertical {
            let centre = CGPoint(x: extent.midX, y: extent.midY)
            let flip = CGAffineTransform(translationX: centre.x, y: centre.y)
                .scaledBy(x: state.flipHorizontal ? -1 : 1, y: state.flipVertical ? -1 : 1)
                .translatedBy(x: -centre.x, y: -centre.y)
            output = output.transformed(by: flip)
            extent = output.extent
        }

        if state.rect != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let pixels = CoordinateSpaceConverter.imageRect(from: state.rect, in: extent.size)
                .offsetBy(dx: extent.minX, dy: extent.minY)
            output = output.cropped(to: pixels.integral)
            // Re-origin at zero so downstream stages see a clean extent.
            output = output.transformed(by: CGAffineTransform(
                translationX: -output.extent.minX,
                y: -output.extent.minY
            ))
        }

        if state.quarterTurns % 4 != 0 {
            output = rotate(output, quarterTurns: state.quarterTurns)
        }

        return output
    }

    /// Whole 90° turns, keeping the result's origin at zero.
    static func rotate(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let extent = image.extent
        guard extent.isRenderable else { return image }

        let angle = -CGFloat(turns) * .pi / 2
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: angle))
        return rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        ))
    }

    /// Fits content into the output frame and fills whatever is left over —
    /// the tool the user sees as "Background".
    ///
    /// This is how a landscape video becomes a vertical export without being
    /// cropped to death.
    static func fit(
        content: CIImage,
        into outputSize: CGSize,
        background: BackgroundStyle,
        backgroundImage: CIImage?,
        quality: RenderQuality
    ) -> CIImage {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let source = content.extent
        guard source.isRenderable, outputRect.isRenderable else { return content }

        let fitScale = min(outputSize.width / source.width, outputSize.height / source.height)
        let fillScale = max(outputSize.width / source.width, outputSize.height / source.height)

        let contentScale: CGFloat
        switch background.fill {
        case .fill:
            contentScale = fillScale
        case .fit, .color, .blur, .image:
            contentScale = fitScale
        }
        let scale = contentScale * CGFloat(max(background.contentScale, 0.05))

        let scaled = content
            .transformed(by: CGAffineTransform(translationX: -source.midX, y: -source.midY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: outputRect.midX, y: outputRect.midY))

        // Already covers the frame: nothing to fill.
        if scaled.extent.contains(outputRect) {
            return scaled.cropped(to: outputRect)
        }

        let plate = backgroundPlate(
            for: background,
            content: content,
            backgroundImage: backgroundImage,
            outputRect: outputRect,
            quality: quality
        )

        let over = CIFilter.sourceOverCompositing()
        over.inputImage = scaled.cropped(to: outputRect)
        over.backgroundImage = plate
        return over.outputImage?.cropped(to: outputRect) ?? scaled.cropped(to: outputRect)
    }

    private static func backgroundPlate(
        for background: BackgroundStyle,
        content: CIImage,
        backgroundImage: CIImage?,
        outputRect: CGRect,
        quality: RenderQuality
    ) -> CIImage {
        switch background.fill {
        case .fit:
            return CIImage(color: .black).cropped(to: outputRect)

        case .fill:
            return CIImage(color: .black).cropped(to: outputRect)

        case .color:
            return CIImage(color: CIColor(background.color)).cropped(to: outputRect)

        case .blur:
            // The content itself, scaled to cover and blurred hard — the look
            // people expect when a horizontal video is posted vertically.
            let source = content.extent
            guard source.isRenderable else {
                return CIImage(color: .black).cropped(to: outputRect)
            }
            let coverScale = max(outputRect.width / source.width, outputRect.height / source.height) * 1.15
            let covered = content
                .transformed(by: CGAffineTransform(translationX: -source.midX, y: -source.midY))
                .transformed(by: CGAffineTransform(scaleX: coverScale, y: coverScale))
                .transformed(by: CGAffineTransform(translationX: outputRect.midX, y: outputRect.midY))

            let blur = CIFilter.gaussianBlur()
            blur.inputImage = covered.clampedToExtent()
            blur.radius = Float(background.blurAmount * min(outputRect.width, outputRect.height)
                * 0.12 * quality.samplingScale)
            let blurred = blur.outputImage?.cropped(to: outputRect)
                ?? covered.cropped(to: outputRect)

            // Darkening keeps the backdrop from competing with the content.
            let darken = CIFilter.colorControls()
            darken.inputImage = blurred
            darken.brightness = -0.12
            darken.contrast = 0.94
            darken.saturation = 1
            return darken.outputImage?.cropped(to: outputRect) ?? blurred

        case .image:
            guard let backgroundImage, backgroundImage.extent.isRenderable else {
                return CIImage(color: .black).cropped(to: outputRect)
            }
            let source = backgroundImage.extent
            let coverScale = max(outputRect.width / source.width, outputRect.height / source.height)
            return backgroundImage
                .transformed(by: CGAffineTransform(translationX: -source.midX, y: -source.midY))
                .transformed(by: CGAffineTransform(scaleX: coverScale, y: coverScale))
                .transformed(by: CGAffineTransform(translationX: outputRect.midX, y: outputRect.midY))
                .cropped(to: outputRect)
        }
    }

    /// Applies a clip's pan-and-zoom transform inside the output frame.
    static func applyTransform(_ transform: LayerTransform, to image: CIImage, outputRect: CGRect) -> CIImage {
        guard !transform.isIdentity else { return image }
        let source = image.extent
        guard source.isRenderable, outputRect.isRenderable else { return image }

        let target = CoordinateSpaceConverter.imagePoint(from: transform.position, in: outputRect.size)
        var affine = CGAffineTransform.identity
        affine = affine.translatedBy(x: target.x + outputRect.minX, y: target.y + outputRect.minY)
        affine = affine.rotated(by: CGFloat(-transform.rotation))
        affine = affine.scaledBy(
            x: CGFloat(transform.scale) * (transform.isFlippedHorizontally ? -1 : 1),
            y: CGFloat(transform.scale) * (transform.isFlippedVertically ? -1 : 1)
        )
        affine = affine.translatedBy(x: -source.midX, y: -source.midY)
        return image.transformed(by: affine)
    }
}
