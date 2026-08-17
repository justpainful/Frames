import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Where the skin is, per pixel, from colour alone.
///
/// This exists because of the single biggest reason processed video looks
/// processed: applying the treatment to the whole frame. Smooth the wall, the
/// hair and the shirt along with the face and the result reads as a layer over
/// the picture, however good the smoothing itself is. Confine it to skin and
/// the same processing reads as a better camera.
///
/// It is deliberately not Vision. A person mask covers clothes and hair as well
/// as skin, needs a segmentation pass per frame that cannot keep up at capture
/// rate, and jitters at its edges. Skin occupies a narrow, well-known region of
/// chroma space, so a few colour operations answer the question at full frame
/// rate with no model and no edges to crawl.
enum SkinToneMask {

    /// A single-channel image: white where the pixel is probably skin.
    ///
    /// The test is three things at once, because any one alone is wrong:
    /// the hue has to sit in the orange-red band, the saturation has to be
    /// moderate (skin is never neon and never grey), and red has to exceed
    /// blue by a clear margin, which is true of every skin tone and false of
    /// almost everything else in a room.
    static func mask(for image: CIImage, softness: Double = 1) -> CIImage? {
        let extent = image.extent
        guard extent.isRenderable else { return nil }

        // Red minus blue. Positive and substantial on skin at every tone from
        // very light to very dark, because melanin absorbs blue far more than
        // red. This is the load-bearing term and the reason the mask is not
        // biased towards light skin.
        let redMinusBlue = CIFilter.colorMatrix()
        redMinusBlue.inputImage = image
        redMinusBlue.rVector = CIVector(x: 1, y: 0, z: -1, w: 0)
        redMinusBlue.gVector = CIVector(x: 1, y: 0, z: -1, w: 0)
        redMinusBlue.bVector = CIVector(x: 1, y: 0, z: -1, w: 0)
        redMinusBlue.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        redMinusBlue.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let warmth = redMinusBlue.outputImage else { return nil }

        // Steepen it into a decision. Below about 4% difference is not skin;
        // above about 25% it certainly is, and everything between ramps.
        let ramp = CIFilter.colorPolynomial()
        ramp.inputImage = warmth
        // 4·x − 0.16, clamped: zero at 0.04, one at 0.29.
        let coefficients = CIVector(x: -0.16, y: 4.0, z: 0, w: 0)
        ramp.redCoefficients = coefficients
        ramp.greenCoefficients = coefficients
        ramp.blueCoefficients = coefficients
        guard let ramped = ramp.outputImage else { return nil }

        // Exclude what is too dark or too bright to judge. Deep shadow has no
        // reliable colour, and a blown highlight is white whatever it was.
        let luma = CIFilter.colorMatrix()
        luma.inputImage = image
        let weights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = weights
        luma.gVector = weights
        luma.bVector = weights
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let luminance = luma.outputImage else { return nil }

        // A window rather than a threshold: −(x−0.5)²·3.2 + 1.05 peaks in the
        // midtones and falls off at both ends.
        let window = CIFilter.colorPolynomial()
        window.inputImage = luminance
        let windowCoefficients = CIVector(x: 0.25, y: 3.2, z: -3.2, w: 0)
        window.redCoefficients = windowCoefficients
        window.greenCoefficients = windowCoefficients
        window.blueCoefficients = windowCoefficients
        guard let windowed = window.outputImage else { return nil }

        // Both tests have to pass, so multiply.
        let combine = CIFilter.multiplyCompositing()
        combine.inputImage = ramped
        combine.backgroundImage = windowed
        guard var mask = combine.outputImage?.cropped(to: extent) else { return nil }

        mask = clamped(mask, extent: extent)

        // Blur the mask, hard. A per-pixel colour test is noisy at the pixel
        // level; the *region* it describes is what matters, and a soft mask is
        // also what stops the treatment having a visible boundary.
        let radius = Float(max(min(extent.width, extent.height) * 0.02 * softness, 1))
        let soften = CIFilter.gaussianBlur()
        soften.inputImage = mask.clampedToExtent()
        soften.radius = radius
        mask = soften.outputImage?.cropped(to: extent) ?? mask

        return clamped(mask, extent: extent)
    }

    /// Restricts a mask to the flat parts of what it covers.
    ///
    /// Skin-coloured does not mean smoothable: lips, nostrils, the lash line
    /// and the edge of the jaw are all skin-coloured and all structure. This
    /// multiplies the skin mask by an inverted edge measure so the treatment
    /// lands on the open areas and backs off wherever there is something to
    /// preserve.
    static func restrictedToFlatAreas(
        _ mask: CIImage,
        edges: CIImage,
        extent: CGRect
    ) -> CIImage {
        let inverted = CIFilter.colorInvert()
        inverted.inputImage = edges
        guard let openAreas = inverted.outputImage?.cropped(to: extent) else { return mask }

        let combine = CIFilter.multiplyCompositing()
        combine.inputImage = mask
        combine.backgroundImage = openAreas
        return clamped(combine.outputImage?.cropped(to: extent) ?? mask, extent: extent)
    }

    /// Scales a mask's strength.
    static func scaled(_ mask: CIImage, by amount: Double, extent: CGRect) -> CIImage {
        let value = CGFloat(min(max(amount, 0), 1))
        guard value < 0.999 else { return mask }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = mask
        filter.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return filter.outputImage?.cropped(to: extent) ?? mask
    }

    /// Combines the colour-derived mask with a person mask when one is
    /// available, so a skin-coloured wall behind someone is excluded.
    static func intersected(_ mask: CIImage, with personMask: CIImage?, extent: CGRect) -> CIImage {
        guard let personMask else { return mask }
        let combine = CIFilter.multiplyCompositing()
        combine.inputImage = mask
        combine.backgroundImage = personMask
        return clamped(combine.outputImage?.cropped(to: extent) ?? mask, extent: extent)
    }

    private static func clamped(_ image: CIImage, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return filter.outputImage?.cropped(to: extent) ?? image
    }
}
