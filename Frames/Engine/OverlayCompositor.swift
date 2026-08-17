import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PencilKit
import UIKit

/// Images an overlay needs that the composer cannot produce itself.
///
/// Decoding an overlay's source image on every frame would be absurd, so they
/// are resolved once and passed in. The composer stays synchronous and pure,
/// which is what lets it run inside an `AVVideoCompositing` callback.
struct OverlayResources {
    /// Decoded overlay images, by asset id.
    var images: [UUID: CIImage] = [:]
    /// Background-removed cut-outs, by overlay id, used when
    /// `ImageOverlay.isBackgroundRemoved` is set.
    var cutouts: [UUID: CIImage] = [:]
    /// Rasterised drawings, by drawing id.
    var drawings: [UUID: CIImage] = [:]

    static let empty = OverlayResources()
}

/// Composites text, images and drawings over the graded frame.
enum OverlayCompositor {

    static func composite(
        document: EditDocument,
        onto base: CIImage,
        time: TimeInterval,
        resources: OverlayResources,
        quality: RenderQuality
    ) -> CIImage {
        let extent = base.extent
        guard extent.isRenderable else { return base }
        var output = base

        for overlay in document.imageOverlays where overlay.isVisible(at: time) {
            output = compositeImageOverlay(overlay, onto: output, extent: extent, time: time,
                                           resources: resources, quality: quality)
        }

        for drawing in document.drawings where drawing.isVisible(at: time) {
            output = compositeDrawing(drawing, onto: output, extent: extent, resources: resources)
        }

        for overlay in document.textOverlays where overlay.isVisible(at: time) {
            output = compositeText(overlay, onto: output, extent: extent, time: time)
        }

        return output
    }

    // MARK: - Image overlays

    private static func compositeImageOverlay(
        _ overlay: ImageOverlay,
        onto base: CIImage,
        extent: CGRect,
        time: TimeInterval,
        resources: OverlayResources,
        quality: RenderQuality
    ) -> CIImage {
        let source: CIImage?
        if overlay.isBackgroundRemoved, let cutout = resources.cutouts[overlay.id] {
            source = cutout
        } else {
            source = resources.images[overlay.assetID]
        }
        guard var layer = source, layer.extent.isRenderable else { return base }

        if !overlay.crop.isIdentity {
            layer = GeometryRenderer.applyCrop(overlay.crop, to: layer)
        }
        if !overlay.adjustments.isIdentity {
            layer = AdjustmentRenderer.apply(overlay.adjustments, to: layer, quality: quality)
        }
        if overlay.cornerRadius > 0.001 {
            layer = roundCorners(layer, radius: overlay.cornerRadius)
        }
        if overlay.border.isEnabled, overlay.border.width > 0 {
            layer = addBorder(overlay.border, to: layer, compositionHeight: extent.height)
        }

        let transform = overlay.transform.evaluated(with: overlay.keyframes, at: time)
        layer = place(layer, transform: transform, in: extent)

        if overlay.shadow.isEnabled {
            layer = addShadow(overlay.shadow, to: layer, compositionHeight: extent.height, extent: extent)
        }

        return blend(layer, over: base, mode: overlay.blendMode, extent: extent)
    }

    // MARK: - Drawings

    private static func compositeDrawing(
        _ drawing: DrawingOverlay,
        onto base: CIImage,
        extent: CGRect,
        resources: OverlayResources
    ) -> CIImage {
        var layers: [CIImage] = []

        if let raster = resources.drawings[drawing.id], raster.extent.isRenderable {
            layers.append(fitToExtent(raster, extent: extent))
        }
        if !drawing.shapes.isEmpty, let shapes = renderShapes(drawing.shapes, extent: extent) {
            layers.append(shapes)
        }
        guard !layers.isEmpty else { return base }

        var output = base
        for layer in layers {
            let faded = drawing.opacity < 0.999
                ? scaleAlpha(layer, by: drawing.opacity, extent: extent)
                : layer
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = faded
            over.backgroundImage = output
            output = over.outputImage?.cropped(to: extent) ?? output
        }
        return output
    }

    /// Rasterises the vector shape tools.
    static func renderShapes(_ shapes: [VectorShape], extent: CGRect) -> CIImage? {
        guard extent.isRenderable else { return nil }
        let size = CGSize(width: extent.width, height: extent.height)
        guard size.width < 16384, size.height < 16384 else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setLineCap(.round)
            cgContext.setLineJoin(.round)

            for shape in shapes {
                // The renderer's context is top-left origin, which is the same
                // convention the model stores points in — no flip needed here.
                let start = CGPoint(x: shape.start.x * size.width, y: shape.start.y * size.height)
                let end = CGPoint(x: shape.end.x * size.width, y: shape.end.y * size.height)
                let width = max(CGFloat(shape.lineWidth) * min(size.width, size.height), 1)
                let color = UIColor(shape.color)
                cgContext.setStrokeColor(color.cgColor)
                cgContext.setFillColor(color.cgColor)
                cgContext.setLineWidth(width)

                switch shape.kind {
                case .line:
                    cgContext.move(to: start)
                    cgContext.addLine(to: end)
                    cgContext.strokePath()

                case .arrow:
                    cgContext.move(to: start)
                    cgContext.addLine(to: end)
                    cgContext.strokePath()
                    drawArrowhead(from: start, to: end, width: width, in: cgContext)

                case .rectangle:
                    let rect = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                    if shape.isFilled {
                        cgContext.fill(rect)
                    } else {
                        cgContext.stroke(rect)
                    }

                case .ellipse:
                    let rect = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                    if shape.isFilled {
                        cgContext.fillEllipse(in: rect)
                    } else {
                        cgContext.strokeEllipse(in: rect)
                    }
                }
            }
        }

        guard let cgImage = image.cgImage else { return nil }
        // The bitmap is top-left origin; Core Image is bottom-left.
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -size.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private static func drawArrowhead(from start: CGPoint, to end: CGPoint, width: CGFloat, in context: CGContext) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = max(width * 3.2, 8)
        let spread = CGFloat.pi / 7

        context.move(to: end)
        context.addLine(to: CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        ))
        context.addLine(to: CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        ))
        context.closePath()
        context.fillPath()
    }

    /// Rasterises a PencilKit drawing at composition size.
    static func rasterise(_ drawing: DrawingOverlay, size: CGSize) -> CIImage? {
        guard !drawing.pencilData.isEmpty else { return nil }
        guard size.width > 0, size.height > 0, size.width < 16384, size.height < 16384 else { return nil }
        guard let pkDrawing = try? PKDrawing(data: drawing.pencilData) else { return nil }

        let image = pkDrawing.image(from: CGRect(origin: .zero, size: size), scale: 1)
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -size.height))
    }

    // MARK: - Text

    private static func compositeText(
        _ overlay: TextOverlay,
        onto base: CIImage,
        extent: CGRect,
        time: TimeInterval
    ) -> CIImage {
        guard let rendered = TextLayerRenderer.render(
            overlay,
            compositionSize: extent.size,
            time: time
        ) else { return base }

        let animation = overlay.animationState(at: time)
        var transform = overlay.transform.evaluated(with: overlay.keyframes, at: time)
        transform.scale *= animation.scale
        transform.opacity *= animation.opacity
        transform.position.x += animation.offsetX
        transform.position.y += animation.offsetY

        // The rendered bitmap is top-left origin; flip it into Core Image space
        // before placing it.
        let flipped = rendered.image
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -rendered.size.height))

        let placed = place(flipped, transform: transform, in: extent)
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = placed
        over.backgroundImage = base
        return over.outputImage?.cropped(to: extent) ?? base
    }

    // MARK: - Placement

    /// Positions a layer in composition space according to a `LayerTransform`.
    static func place(_ layer: CIImage, transform: LayerTransform, in extent: CGRect) -> CIImage {
        let source = layer.extent
        guard source.isRenderable else { return layer }

        let centre = CoordinateSpaceConverter.imagePoint(from: transform.position, in: extent.size)
        var affine = CGAffineTransform.identity
        affine = affine.translatedBy(x: centre.x + extent.minX, y: centre.y + extent.minY)
        affine = affine.rotated(by: CGFloat(-transform.rotation))
        affine = affine.scaledBy(
            x: CGFloat(transform.scale) * (transform.isFlippedHorizontally ? -1 : 1),
            y: CGFloat(transform.scale) * (transform.isFlippedVertically ? -1 : 1)
        )
        affine = affine.translatedBy(x: -source.midX, y: -source.midY)

        var placed = layer.transformed(by: affine)
        if transform.opacity < 0.999 {
            placed = scaleAlpha(placed, by: transform.opacity, extent: placed.extent)
        }
        return placed
    }

    /// Scales a layer to exactly cover an extent, used for full-frame rasters.
    private static func fitToExtent(_ layer: CIImage, extent: CGRect) -> CIImage {
        let source = layer.extent
        guard source.isRenderable else { return layer }
        let scaleX = extent.width / source.width
        let scaleY = extent.height / source.height
        return layer
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    // MARK: - Layer decoration

    private static func roundCorners(_ layer: CIImage, radius: Double) -> CIImage {
        let extent = layer.extent
        guard extent.isRenderable else { return layer }
        let pixels = CGFloat(radius) * min(extent.width, extent.height)
        guard pixels > 0.5 else { return layer }

        guard let mask = solidMask(extent: extent, cornerRadius: pixels) else { return layer }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = layer
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? layer
    }

    private static func addBorder(_ border: BorderStyle, to layer: CIImage, compositionHeight: CGFloat) -> CIImage {
        let extent = layer.extent
        guard extent.isRenderable else { return layer }
        let width = max(CGFloat(border.width) * compositionHeight, 1)

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        guard extent.width < 16384, extent.height < 16384 else { return layer }

        let renderer = UIGraphicsImageRenderer(size: extent.size, format: format)
        let stroke = renderer.image { context in
            context.cgContext.setStrokeColor(UIColor(border.color).cgColor)
            context.cgContext.setLineWidth(width)
            context.cgContext.stroke(
                CGRect(origin: .zero, size: extent.size).insetBy(dx: width / 2, dy: width / 2)
            )
        }
        guard let cgStroke = stroke.cgImage else { return layer }

        let strokeImage = CIImage(cgImage: cgStroke)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = strokeImage
        over.backgroundImage = layer
        return over.outputImage?.cropped(to: extent) ?? layer
    }

    private static func addShadow(
        _ shadow: ShadowStyle,
        to layer: CIImage,
        compositionHeight: CGFloat,
        extent: CGRect
    ) -> CIImage {
        let radius = Float(CGFloat(shadow.radius) * compositionHeight)
        guard radius > 0.5 else { return layer }

        // Take the layer's alpha, tint it, blur it, and put the layer back on
        // top: a real drop shadow rather than a duplicated image.
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = layer
        matrix.rVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(shadow.color.red))
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(shadow.color.green))
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(shadow.color.blue))
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(shadow.opacity))
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let silhouette = matrix.outputImage else { return layer }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = silhouette
        blur.radius = radius
        guard let blurred = blur.outputImage else { return layer }

        let offset = blurred.transformed(by: CGAffineTransform(
            translationX: CGFloat(shadow.offsetX) * compositionHeight,
            y: -CGFloat(shadow.offsetY) * compositionHeight
        ))

        let over = CIFilter.sourceOverCompositing()
        over.inputImage = layer
        over.backgroundImage = offset
        return over.outputImage ?? layer
    }

    // MARK: - Blending

    private static func blend(
        _ layer: CIImage,
        over base: CIImage,
        mode: OverlayBlendMode,
        extent: CGRect
    ) -> CIImage {
        let filter: any CIFilter & CICompositeOperation
        switch mode {
        case .normal:
            let over = CIFilter.sourceOverCompositing()
            over.inputImage = layer
            over.backgroundImage = base
            return over.outputImage?.cropped(to: extent) ?? base
        case .multiply:
            filter = CIFilter.multiplyBlendMode()
        case .screen:
            filter = CIFilter.screenBlendMode()
        case .overlay:
            filter = CIFilter.overlayBlendMode()
        case .softLight:
            filter = CIFilter.softLightBlendMode()
        case .luminosity:
            filter = CIFilter.luminosityBlendMode()
        }
        filter.inputImage = layer
        filter.backgroundImage = base
        return filter.outputImage?.cropped(to: extent) ?? base
    }

    private static func scaleAlpha(_ image: CIImage, by factor: Double, extent: CGRect) -> CIImage {
        guard factor < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(factor, 0)))
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    private static func solidMask(extent: CGRect, cornerRadius: CGFloat) -> CIImage? {
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0, width < 16384, height < 16384 else { return nil }
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
            cornerWidth: min(cornerRadius, CGFloat(width) / 2),
            cornerHeight: min(cornerRadius, CGFloat(height) / 2),
            transform: nil
        ))
        context.fillPath()

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
