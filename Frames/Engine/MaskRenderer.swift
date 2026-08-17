import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Detected geometry that masks can refer to.
///
/// Vision results are resolved once per frame and handed to the renderer, so a
/// frame with four face blurs runs face detection once, not four times.
struct DetectionContext: Sendable {
    /// Faces by their stable detection id, in normalized top-left space.
    var faces: [UUID: CGRect] = [:]
    /// Person instance masks, by instance index. Values are single-channel
    /// images in composition pixel space.
    var personMasks: [Int: CIImage] = [:]
    /// The foreground subject mask, if one was found.
    var subjectMask: CIImage?
    /// Tracked objects by id, resolved to this frame's time.
    var trackedRects: [UUID: CGRect] = [:]

    static let empty = DetectionContext()
}

/// Builds the grayscale image a mask represents.
///
/// One implementation serves blur, selective adjustment, effects and overlays.
/// The output is always a single-channel image in composition pixel space where
/// white means "fully affected".
enum MaskRenderer {

    /// Produces the mask image for `definition`, or `nil` when the mask cannot
    /// be resolved (a face that is no longer detected, for instance) so the
    /// caller can skip the whole stage rather than blurring the entire frame.
    static func mask(
        for definition: MaskDefinition,
        extent: CGRect,
        time: TimeInterval,
        detections: DetectionContext,
        quality: RenderQuality
    ) -> CIImage? {
        var mask: CIImage?

        switch definition.shape {
        case .rectangle:
            mask = shapeMask(definition, extent: extent, time: time, cornerRadius: 0, detections: detections)
        case .roundedRectangle(let cornerRadius):
            mask = shapeMask(definition, extent: extent, time: time, cornerRadius: cornerRadius, detections: detections)
        case .ellipse:
            mask = ellipseMask(definition, extent: extent, time: time, detections: detections)
        case .linearGradient(let angle):
            mask = linearGradientMask(definition, extent: extent, time: time, angle: angle)
        case .radialGradient:
            mask = radialGradientMask(definition, extent: extent, time: time)
        case .freeform(let points):
            mask = freeformMask(points, extent: extent)
        case .person(let instance):
            mask = detections.personMasks[instance].map { resample($0, to: extent) }
        case .face(let detectionID):
            guard let rect = detections.faces[detectionID] else { return nil }
            mask = faceMask(rect, definition: definition, extent: extent)
        case .foregroundSubject:
            guard let subject = detections.subjectMask else { return nil }
            mask = resample(subject, to: extent)
        }

        guard var output = mask else { return nil }

        if definition.feather > 0.001 {
            let radius = Float(definition.feather * 0.06 * min(extent.width, extent.height) * quality.samplingScale)
            if radius > 0.5 {
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = output.clampedToExtent()
                blur.radius = radius
                output = blur.outputImage?.cropped(to: extent) ?? output
            }
        }

        if definition.isInverted {
            output = invert(output, extent: extent)
        }

        let opacity = definition.transform.evaluated(with: definition.keyframes, at: time).opacity
        if opacity < 0.999 {
            output = scaleAlpha(output, by: opacity, extent: extent)
        }

        return output
    }

    // MARK: - Shapes

    private static func resolvedBox(
        _ definition: MaskDefinition,
        extent: CGRect,
        time: TimeInterval,
        detections: DetectionContext
    ) -> (rect: CGRect, rotation: Double) {
        if let trackedID = definition.trackedObjectID, let tracked = detections.trackedRects[trackedID] {
            return (CoordinateSpaceConverter.imageRect(from: tracked, in: extent.size), 0)
        }
        let transform = definition.transform.evaluated(with: definition.keyframes, at: time)
        let width = definition.size.width * transform.scale
        let height = definition.size.height * transform.scale
        let normalized = CGRect(
            x: transform.position.x - width / 2,
            y: transform.position.y - height / 2,
            width: width,
            height: height
        )
        return (CoordinateSpaceConverter.imageRect(from: normalized, in: extent.size), transform.rotation)
    }

    private static func shapeMask(
        _ definition: MaskDefinition,
        extent: CGRect,
        time: TimeInterval,
        cornerRadius: Double,
        detections: DetectionContext
    ) -> CIImage? {
        let resolved = resolvedBox(definition, extent: extent, time: time, detections: detections)
        return rasterise(extent: extent, rotation: resolved.rotation, centre: CGPoint(x: resolved.rect.midX, y: resolved.rect.midY)) { context in
            let radius = CGFloat(cornerRadius) * min(resolved.rect.width, resolved.rect.height)
            let path = CGPath(
                roundedRect: resolved.rect,
                cornerWidth: min(radius, resolved.rect.width / 2),
                cornerHeight: min(radius, resolved.rect.height / 2),
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
        }
    }

    private static func ellipseMask(
        _ definition: MaskDefinition,
        extent: CGRect,
        time: TimeInterval,
        detections: DetectionContext
    ) -> CIImage? {
        let resolved = resolvedBox(definition, extent: extent, time: time, detections: detections)
        return rasterise(extent: extent, rotation: resolved.rotation, centre: CGPoint(x: resolved.rect.midX, y: resolved.rect.midY)) { context in
            context.addEllipse(in: resolved.rect)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
        }
    }

    private static func faceMask(_ rect: CGRect, definition: MaskDefinition, extent: CGRect) -> CIImage? {
        // Faces are reported tightly; widening a little covers hair and chin,
        // which is what people expect "blur this face" to mean.
        let padded = rect.insetBy(dx: -rect.width * 0.14, dy: -rect.height * 0.18)
        let pixels = CoordinateSpaceConverter.imageRect(from: padded, in: extent.size)
        return rasterise(extent: extent, rotation: 0, centre: CGPoint(x: pixels.midX, y: pixels.midY)) { context in
            context.addEllipse(in: pixels)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
        }
    }

    private static func freeformMask(_ points: [CGPoint], extent: CGRect) -> CIImage? {
        guard points.count >= 3 else { return nil }
        return rasterise(extent: extent, rotation: 0, centre: .zero) { context in
            let converted = points.map {
                CoordinateSpaceConverter.imagePoint(from: $0, in: extent.size)
            }
            context.move(to: converted[0])
            for point in converted.dropFirst() {
                context.addLine(to: point)
            }
            context.closePath()
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
        }
    }

    private static func linearGradientMask(
        _ definition: MaskDefinition,
        extent: CGRect,
        time: TimeInterval,
        angle: Double
    ) -> CIImage? {
        let transform = definition.transform.evaluated(with: definition.keyframes, at: time)
        let centre = CoordinateSpaceConverter.imagePoint(from: transform.position, in: extent.size)
        let reach = max(extent.width, extent.height) * CGFloat(definition.size.height * transform.scale)
        let direction = CGPoint(x: cos(angle), y: sin(angle))

        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: centre.x - direction.x * reach / 2, y: centre.y - direction.y * reach / 2)
        filter.point1 = CGPoint(x: centre.x + direction.x * reach / 2, y: centre.y + direction.y * reach / 2)
        filter.color0 = CIColor.black
        filter.color1 = CIColor.white
        return filter.outputImage?.cropped(to: extent)
    }

    private static func radialGradientMask(
        _ definition: MaskDefinition,
        extent: CGRect,
        time: TimeInterval
    ) -> CIImage? {
        let transform = definition.transform.evaluated(with: definition.keyframes, at: time)
        let centre = CoordinateSpaceConverter.imagePoint(from: transform.position, in: extent.size)
        let outer = max(extent.width, extent.height)
            * CGFloat(max(definition.size.width, definition.size.height) * transform.scale) / 2

        let filter = CIFilter.radialGradient()
        filter.center = centre
        filter.radius0 = Float(max(outer * 0.25, 1))
        filter.radius1 = Float(max(outer, 2))
        filter.color0 = CIColor.white
        filter.color1 = CIColor.black
        return filter.outputImage?.cropped(to: extent)
    }

    // MARK: - Helpers

    /// Draws a shape into a one-shot bitmap and wraps it as a `CIImage`.
    ///
    /// Core Generators cannot express rounded rectangles or polygons, and
    /// building them from `CIFilter` primitives costs more passes than a single
    /// small rasterisation.
    private static func rasterise(
        extent: CGRect,
        rotation: Double,
        centre: CGPoint,
        draw: (CGContext) -> Void
    ) -> CIImage? {
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if abs(rotation) > 0.0001 {
            context.translateBy(x: centre.x, y: centre.y)
            context.rotate(by: CGFloat(-rotation))
            context.translateBy(x: -centre.x, y: -centre.y)
        }

        draw(context)

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(
            by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y)
        )
    }

    private static func resample(_ mask: CIImage, to extent: CGRect) -> CIImage {
        guard mask.extent.width > 0, mask.extent.height > 0 else { return mask }
        let scaleX = extent.width / mask.extent.width
        let scaleY = extent.height / mask.extent.height
        guard abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 else { return mask }
        return mask
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: extent)
    }

    private static func invert(_ mask: CIImage, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorInvert()
        filter.inputImage = mask
        return filter.outputImage?.cropped(to: extent) ?? mask
    }

    private static func scaleAlpha(_ mask: CIImage, by factor: Double, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = mask
        let value = CGFloat(min(max(factor, 0), 1))
        filter.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return filter.outputImage?.cropped(to: extent) ?? mask
    }

    /// Composites `effect` over `base` through `mask`.
    static func blend(effect: CIImage, over base: CIImage, using mask: CIImage, extent: CGRect) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = effect
        filter.backgroundImage = base
        filter.maskImage = mask
        return filter.outputImage?.cropped(to: extent) ?? base
    }
}
