import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Blends the outgoing and incoming clips during a transition.
enum TransitionRenderer {

    static func blend(
        from outgoing: CIImage,
        to incoming: CIImage,
        transition: Transition,
        progress: Double,
        extent: CGRect
    ) -> CIImage {
        guard extent.isRenderable else { return incoming }
        let t = min(max(progress, 0), 1)

        switch transition.kind {
        case .none:
            return t < 0.5 ? outgoing : incoming

        case .dissolve:
            return mix(outgoing, incoming, amount: t, extent: extent)

        case .fadeThroughBlack:
            return through(colour: CIColor.black, outgoing: outgoing, incoming: incoming, t: t, extent: extent)

        case .fadeThroughWhite:
            return through(colour: CIColor.white, outgoing: outgoing, incoming: incoming, t: t, extent: extent)

        case .slide:
            let offset = extent.width * CGFloat(1 - t)
            let moved = incoming.transformed(by: CGAffineTransform(translationX: offset, y: 0))
            let pushed = outgoing.transformed(by: CGAffineTransform(translationX: -extent.width * CGFloat(t), y: 0))
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = moved
            over.backgroundImage = pushed
            return over.outputImage?.cropped(to: extent) ?? incoming

        case .blur:
            // Both sides blur towards the midpoint and sharpen out of it, which
            // reads as a soft cut rather than as two blurred images crossfading.
            let bell = sin(t * .pi)
            let radius = Float(bell * min(extent.width, extent.height) * 0.05)
            let softOutgoing = blur(outgoing, radius: radius, extent: extent)
            let softIncoming = blur(incoming, radius: radius, extent: extent)
            return mix(softOutgoing, softIncoming, amount: t, extent: extent)

        case .zoom:
            let outScale = 1 + 0.18 * t
            let inScale = 1.18 - 0.18 * t
            let zoomedOut = scale(outgoing, by: outScale, extent: extent)
            let zoomedIn = scale(incoming, by: inScale, extent: extent)
            return mix(zoomedOut, zoomedIn, amount: t, extent: extent)
        }
    }

    // MARK: - Pieces

    private static func mix(_ a: CIImage, _ b: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = a
        filter.targetImage = b
        filter.time = Float(min(max(amount, 0), 1))
        return filter.outputImage?.cropped(to: extent) ?? (amount < 0.5 ? a : b)
    }

    private static func through(
        colour: CIColor,
        outgoing: CIImage,
        incoming: CIImage,
        t: Double,
        extent: CGRect
    ) -> CIImage {
        let plate = CIImage(color: colour).cropped(to: extent)
        if t < 0.5 {
            return mix(outgoing, plate, amount: t * 2, extent: extent)
        }
        return mix(plate, incoming, amount: (t - 0.5) * 2, extent: extent)
    }

    private static func blur(_ image: CIImage, radius: Float, extent: CGRect) -> CIImage {
        guard radius > 0.5 else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = radius
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    private static func scale(_ image: CIImage, by factor: Double, extent: CGRect) -> CIImage {
        guard abs(factor - 1) > 0.001 else { return image }
        let transform = CGAffineTransform(translationX: extent.midX, y: extent.midY)
            .scaledBy(x: CGFloat(factor), y: CGFloat(factor))
            .translatedBy(x: -extent.midX, y: -extent.midY)
        return image.clampedToExtent().transformed(by: transform).cropped(to: extent)
    }
}
