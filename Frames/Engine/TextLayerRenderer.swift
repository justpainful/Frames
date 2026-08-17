import CoreGraphics
import CoreImage
import CoreText
import Foundation
import UIKit

/// Draws a text overlay.
///
/// Text is laid out with Core Text rather than assembled from Core Image
/// generators, because correct Arabic needs real shaping, bidirectional
/// reordering and a natural base writing direction — none of which a glyph
/// generator gives you. The same routine draws the preview and the export, at
/// different pixel sizes, from the same normalized style.
enum TextLayerRenderer {

    /// A laid-out text layer, ready to composite.
    struct Rendered {
        let image: CIImage
        /// Size of the drawn image in composition pixels.
        let size: CGSize
    }

    static func render(
        _ overlay: TextOverlay,
        compositionSize: CGSize,
        time: TimeInterval,
        scale: CGFloat = 1
    ) -> Rendered? {
        guard !overlay.isEmpty else { return nil }
        guard compositionSize.width > 0, compositionSize.height > 0 else { return nil }

        let style = overlay.style
        let animation = overlay.animationState(at: time)
        let pointSize = max(style.fontSize * compositionSize.height * scale, 4)
        let font = makeFont(style: style, pixelSize: pointSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsAlignment(style.alignment)
        paragraph.lineHeightMultiple = CGFloat(max(style.lineSpacing, 0.5))
        // `.natural` is what makes an Arabic string lay out right-to-left and an
        // English one left-to-right without the app deciding.
        paragraph.baseWritingDirection = .natural
        paragraph.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(style.color),
            .paragraphStyle: paragraph,
            .kern: pointSize * CGFloat(style.tracking)
        ]
        if style.stroke.isEnabled, style.stroke.width > 0 {
            attributes[.strokeColor] = UIColor(style.stroke.color)
            // Negative width means "stroke and fill", which is what an outline
            // around visible text means.
            attributes[.strokeWidth] = -CGFloat(style.stroke.width * 100)
        }

        let attributed = NSAttributedString(string: overlay.string, attributes: attributes)
        let maxWidth = max(CGFloat(overlay.maximumWidth) * compositionSize.width * scale, pointSize)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraints = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraints,
            nil
        )

        let padding = CGFloat(style.background.padding) * compositionSize.height * scale
        let shadowPad = style.shadow.isEnabled
            ? CGFloat(style.shadow.radius + abs(style.shadow.offsetY) + abs(style.shadow.offsetX)) * compositionSize.height * scale * 2
            : 0
        let inset = padding + shadowPad + pointSize * 0.25

        let canvasSize = CGSize(
            width: ceil(measured.width + inset * 2),
            height: ceil(measured.height + inset * 2)
        )
        guard canvasSize.width > 1, canvasSize.height > 1,
              canvasSize.width < 16384, canvasSize.height < 16384
        else { return nil }

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: opaqueFreeFormat())
        let image = renderer.image { context in
            let cgContext = context.cgContext
            let textRect = CGRect(
                x: inset,
                y: inset,
                width: ceil(measured.width),
                height: ceil(measured.height)
            )

            drawBackground(style.background, textRect: textRect, padding: padding,
                           compositionSize: compositionSize, scale: scale, in: cgContext)

            if style.shadow.isEnabled {
                cgContext.setShadow(
                    offset: CGSize(
                        width: CGFloat(style.shadow.offsetX) * compositionSize.height * scale,
                        height: CGFloat(style.shadow.offsetY) * compositionSize.height * scale
                    ),
                    blur: CGFloat(style.shadow.radius) * compositionSize.height * scale,
                    color: UIColor(style.shadow.color)
                        .withAlphaComponent(CGFloat(style.shadow.opacity)).cgColor
                )
            }

            // Core Text draws bottom-up; flip so the layout matches the rect we
            // measured.
            cgContext.textMatrix = .identity
            cgContext.translateBy(x: 0, y: canvasSize.height)
            cgContext.scaleBy(x: 1, y: -1)

            let flippedRect = CGRect(
                x: textRect.minX,
                y: canvasSize.height - textRect.maxY,
                width: textRect.width,
                height: textRect.height
            )
            let path = CGPath(rect: flippedRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, cgContext)
        }

        guard let cgImage = image.cgImage else { return nil }
        var output = CIImage(cgImage: cgImage)

        if animation.blur > 0.001 {
            let blur = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: output.clampedToExtent(),
                kCIInputRadiusKey: animation.blur * 24
            ])
            output = blur?.outputImage?.cropped(to: output.extent) ?? output
        }

        return Rendered(image: output, size: canvasSize)
    }

    // MARK: - Pieces

    private static func opaqueFreeFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        return format
    }

    private static func drawBackground(
        _ background: TextBackgroundStyle,
        textRect: CGRect,
        padding: CGFloat,
        compositionSize: CGSize,
        scale: CGFloat,
        in context: CGContext
    ) {
        guard background.shape != .none else { return }
        context.setFillColor(UIColor(background.color).cgColor)
        let radius = CGFloat(background.cornerRadius) * compositionSize.height * scale

        switch background.shape {
        case .none:
            break
        case .plate, .perLine:
            // Per-line plates and a single plate differ only in how tightly
            // they hug short lines; both are a rounded rect here because Core
            // Text line rects are measured after wrapping, and a single plate
            // is the calmer default.
            let plate = textRect.insetBy(dx: -padding, dy: -padding)
            context.addPath(CGPath(
                roundedRect: plate,
                cornerWidth: min(radius, plate.width / 2),
                cornerHeight: min(radius, plate.height / 2),
                transform: nil
            ))
            context.fillPath()
        case .underline:
            let bar = CGRect(
                x: textRect.minX - padding / 2,
                y: textRect.maxY,
                width: textRect.width + padding,
                height: max(padding * 0.4, 2)
            )
            context.fill(bar)
        }
    }

    private static func nsAlignment(_ alignment: TextAlignmentChoice) -> NSTextAlignment {
        switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    static func makeFont(style: TextStyle, pixelSize: CGFloat) -> UIFont {
        if let family = style.fontFamily, let named = UIFont(name: family, size: pixelSize) {
            return named
        }

        let base = UIFont.systemFont(ofSize: pixelSize, weight: uiWeight(style.weight))
        var descriptor = base.fontDescriptor

        let design: UIFontDescriptor.SystemDesign? = switch style.design {
        case .system: nil
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
        if let design, let redesigned = descriptor.withDesign(design) {
            descriptor = redesigned
        }
        if style.isItalic, let italic = descriptor.withSymbolicTraits(
            descriptor.symbolicTraits.union(.traitItalic)
        ) {
            descriptor = italic
        }
        return UIFont(descriptor: descriptor, size: pixelSize)
    }

    private static func uiWeight(_ weight: TextWeight) -> UIFont.Weight {
        switch weight {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

extension UIColor {
    /// Bridges the document's stored colour into UIKit.
    convenience init(_ color: RGBAColor) {
        self.init(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }
}

extension CIColor {
    convenience init(_ color: RGBAColor) {
        self.init(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
    }
}
