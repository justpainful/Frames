import CoreGraphics
import Foundation

// MARK: - Coordinate conventions
//
// Everything positional in the edit model is stored in *normalized composition
// space*: x and y in 0...1, origin top-left, y increasing downwards. That
// matches SwiftUI and keeps edits resolution-independent, so a text overlay
// placed on a 1080p preview lands in exactly the same place in a 4K export.
//
// Two conversions exist, and they exist in exactly one place each:
//   • `CoordinateSpaceConverter.imageRect` for Core Image (bottom-left origin)
//   • `CoordinateSpaceConverter.fromVision` for Vision (bottom-left, normalized)

/// Converts between the normalized top-left space the model uses and the
/// bottom-left spaces Core Image and Vision use.
enum CoordinateSpaceConverter {
    /// Converts a normalized top-left rect into pixel coordinates with a
    /// bottom-left origin, as Core Image expects.
    static func imageRect(from normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: (1 - normalized.maxY) * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    /// Converts a normalized top-left rect into normalized bottom-left space.
    static func flippedVertically(_ normalized: CGRect) -> CGRect {
        CGRect(x: normalized.minX, y: 1 - normalized.maxY,
               width: normalized.width, height: normalized.height)
    }

    /// Vision reports normalized rects with a bottom-left origin.
    static func fromVision(_ visionRect: CGRect) -> CGRect {
        flippedVertically(visionRect)
    }

    /// The inverse, for handing a model rect to Vision.
    static func toVision(_ normalized: CGRect) -> CGRect {
        flippedVertically(normalized)
    }

    /// Converts a normalized top-left point into pixel coordinates with a
    /// bottom-left origin.
    static func imagePoint(from normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: (1 - normalized.y) * size.height)
    }
}

/// Position, scale, rotation and opacity of anything that floats over the
/// canvas: text, image overlays, drawings, blur regions.
struct LayerTransform: Codable, Hashable, Sendable {
    /// Centre of the layer, normalized top-left space.
    var position: CGPoint
    /// Uniform scale. 1 means "the layer's natural size".
    var scale: Double
    /// Clockwise rotation in radians.
    var rotation: Double
    var opacity: Double
    var isFlippedHorizontally: Bool
    var isFlippedVertically: Bool

    init(
        position: CGPoint = CGPoint(x: 0.5, y: 0.5),
        scale: Double = 1,
        rotation: Double = 0,
        opacity: Double = 1,
        isFlippedHorizontally: Bool = false,
        isFlippedVertically: Bool = false
    ) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
    }

    static let identity = LayerTransform()

    var isIdentity: Bool { self == .identity }

    /// Keeps a layer from being dragged entirely off-canvas or scaled into
    /// uselessness. Applied after every gesture rather than during, so the
    /// gesture itself stays smooth.
    mutating func clampToUsableBounds() {
        position.x = min(max(position.x, -0.25), 1.25)
        position.y = min(max(position.y, -0.25), 1.25)
        scale = min(max(scale, 0.05), 12)
        opacity = min(max(opacity, 0), 1)
    }
}

/// The aspect ratios offered by the crop tool.
enum AspectPreset: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case free
    case original
    case square
    case fourFive
    case threeFour
    case sixteenNine
    case nineSixteen

    var id: String { rawValue }

    /// Width ÷ height. `nil` means the crop is unconstrained, or follows the
    /// source, which the caller resolves.
    var ratio: CGFloat? {
        switch self {
        case .free, .original: nil
        case .square: 1
        case .fourFive: 4.0 / 5.0
        case .threeFour: 3.0 / 4.0
        case .sixteenNine: 16.0 / 9.0
        case .nineSixteen: 9.0 / 16.0
        }
    }

    var displayName: String {
        switch self {
        case .free: String(localized: "Free", comment: "Crop aspect ratio")
        case .original: String(localized: "Original", comment: "Crop aspect ratio")
        case .square: String(localized: "Square", comment: "Crop aspect ratio")
        case .fourFive: "4:5"
        case .threeFour: "3:4"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }
}

/// A crop, expressed as a normalized rect over the source plus the orientation
/// operations that come with it. Non-destructive: the source pixels are
/// untouched and the crop can be reopened and changed at any time.
struct CropState: Codable, Hashable, Sendable {
    /// Normalized top-left rect over the (straightened) source.
    var rect: CGRect
    /// Whole 90° turns, positive is clockwise.
    var quarterTurns: Int
    /// Fine straightening in radians, within ±20°.
    var straightenAngle: Double
    var flipHorizontal: Bool
    var flipVertical: Bool
    var aspect: AspectPreset

    init(
        rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        quarterTurns: Int = 0,
        straightenAngle: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        aspect: AspectPreset = .free
    ) {
        self.rect = rect
        self.quarterTurns = quarterTurns
        self.straightenAngle = straightenAngle
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.aspect = aspect
    }

    static let identity = CropState()

    var isIdentity: Bool {
        rect == CGRect(x: 0, y: 0, width: 1, height: 1)
            && quarterTurns % 4 == 0
            && straightenAngle == 0
            && !flipHorizontal
            && !flipVertical
    }

    static let maximumStraightenAngle: Double = 20 * .pi / 180

    mutating func normalize() {
        quarterTurns = ((quarterTurns % 4) + 4) % 4
        straightenAngle = min(max(straightenAngle, -Self.maximumStraightenAngle), Self.maximumStraightenAngle)
        let x = min(max(rect.origin.x, 0), 1)
        let y = min(max(rect.origin.y, 0), 1)
        let w = min(max(rect.width, 0.02), 1 - x)
        let h = min(max(rect.height, 0.02), 1 - y)
        rect = CGRect(x: x, y: y, width: w, height: h)
    }

    /// Output aspect ratio for a source of the given ratio, accounting for the
    /// crop rect and any quarter turns.
    func outputAspectRatio(sourceAspectRatio: CGFloat) -> CGFloat {
        guard rect.height > 0 else { return sourceAspectRatio }
        let cropped = sourceAspectRatio * (rect.width / rect.height)
        return quarterTurns % 2 == 0 ? cropped : 1 / cropped
    }
}

/// How the composition frame is filled when the media's aspect ratio doesn't
/// match the output — the tool the user sees as "Background".
struct BackgroundStyle: Codable, Hashable, Sendable {
    enum Fill: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        case fit
        case fill
        case color
        case blur
        case image

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fit: String(localized: "Fit", comment: "Background fill mode")
            case .fill: String(localized: "Fill", comment: "Background fill mode")
            case .color: String(localized: "Color", comment: "Background fill mode")
            case .blur: String(localized: "Blur", comment: "Background fill mode")
            case .image: String(localized: "Image", comment: "Background fill mode")
            }
        }

        var symbolName: String {
            switch self {
            case .fit: "rectangle.arrowtriangle.2.inward"
            case .fill: "rectangle.arrowtriangle.2.outward"
            case .color: "paintpalette"
            case .blur: "drop.halffull"
            case .image: "photo"
            }
        }
    }

    var fill: Fill
    var color: RGBAColor
    /// Blur radius used when `fill` is `.blur`, in normalized units.
    var blurAmount: Double
    /// Asset id of the image used when `fill` is `.image`.
    var imageAssetID: UUID?
    /// Scale applied to the foreground media inside the frame.
    var contentScale: Double

    init(
        fill: Fill = .fit,
        color: RGBAColor = .black,
        blurAmount: Double = 0.6,
        imageAssetID: UUID? = nil,
        contentScale: Double = 1
    ) {
        self.fill = fill
        self.color = color
        self.blurAmount = blurAmount
        self.imageAssetID = imageAssetID
        self.contentScale = contentScale
    }

    static let `default` = BackgroundStyle()
}

/// A colour in extended sRGB, stored as data rather than as a `Color` so the
/// session file stays portable and the render engine can read it directly.
struct RGBAColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// The palette offered wherever the user picks a colour. Kept short and
    /// system-derived rather than a 200-swatch grid.
    static let palette: [RGBAColor] = [
        .white,
        RGBAColor(red: 0.60, green: 0.60, blue: 0.62),
        .black,
        RGBAColor(red: 1.00, green: 0.27, blue: 0.23),
        RGBAColor(red: 1.00, green: 0.58, blue: 0.00),
        RGBAColor(red: 1.00, green: 0.84, blue: 0.04),
        RGBAColor(red: 0.20, green: 0.78, blue: 0.35),
        RGBAColor(red: 0.35, green: 0.78, blue: 0.98),
        RGBAColor(red: 0.04, green: 0.52, blue: 1.00),
        RGBAColor(red: 0.35, green: 0.34, blue: 0.84),
        RGBAColor(red: 0.75, green: 0.35, blue: 0.95),
        RGBAColor(red: 1.00, green: 0.18, blue: 0.57)
    ]
}
