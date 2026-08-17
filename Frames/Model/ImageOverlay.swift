import CoreGraphics
import Foundation

struct BorderStyle: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var color: RGBAColor
    /// Fraction of the composition's smaller dimension.
    var width: Double

    init(isEnabled: Bool = false, color: RGBAColor = .white, width: Double = 0.006) {
        self.isEnabled = isEnabled
        self.color = color
        self.width = width
    }
}

/// Blend modes offered for overlays. A short, useful list rather than the full
/// Core Image compositing catalogue.
enum OverlayBlendMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case normal
    case multiply
    case screen
    case overlay
    case softLight
    case luminosity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: String(localized: "Normal", comment: "Blend mode")
        case .multiply: String(localized: "Multiply", comment: "Blend mode")
        case .screen: String(localized: "Screen", comment: "Blend mode")
        case .overlay: String(localized: "Overlay", comment: "Blend mode")
        case .softLight: String(localized: "Soft Light", comment: "Blend mode")
        case .luminosity: String(localized: "Luminosity", comment: "Blend mode")
        }
    }
}

/// A photo or sticker placed over the media.
struct ImageOverlay: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// The imported asset this overlay draws.
    var assetID: UUID
    var transform: LayerTransform
    var timeRange: TimeRange?
    var crop: CropState
    var cornerRadius: Double
    var border: BorderStyle
    var shadow: ShadowStyle
    var blendMode: OverlayBlendMode
    var adjustments: AdjustmentSet
    /// When true, the render engine substitutes the cached cut-out produced by
    /// Vision. The original asset is kept, so this is fully reversible.
    var isBackgroundRemoved: Bool
    /// Relative file name of the cached cut-out, if one has been produced.
    var cutoutFileName: String?
    var keyframes: KeyframeSet

    init(
        id: UUID = UUID(),
        assetID: UUID,
        transform: LayerTransform = LayerTransform(scale: 0.5),
        timeRange: TimeRange? = nil,
        crop: CropState = .identity,
        cornerRadius: Double = 0,
        border: BorderStyle = BorderStyle(),
        shadow: ShadowStyle = ShadowStyle(),
        blendMode: OverlayBlendMode = .normal,
        adjustments: AdjustmentSet = AdjustmentSet(),
        isBackgroundRemoved: Bool = false,
        cutoutFileName: String? = nil,
        keyframes: KeyframeSet = KeyframeSet()
    ) {
        self.id = id
        self.assetID = assetID
        self.transform = transform
        self.timeRange = timeRange
        self.crop = crop
        self.cornerRadius = cornerRadius
        self.border = border
        self.shadow = shadow
        self.blendMode = blendMode
        self.adjustments = adjustments
        self.isBackgroundRemoved = isBackgroundRemoved
        self.cutoutFileName = cutoutFileName
        self.keyframes = keyframes
    }

    func isVisible(at time: TimeInterval) -> Bool {
        guard let timeRange else { return true }
        return timeRange.contains(time)
    }
}

/// A vector annotation drawn with the shape tools.
struct VectorShape: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        case line
        case arrow
        case rectangle
        case ellipse

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .line: String(localized: "Line", comment: "Shape tool")
            case .arrow: String(localized: "Arrow", comment: "Shape tool")
            case .rectangle: String(localized: "Rectangle", comment: "Shape tool")
            case .ellipse: String(localized: "Circle", comment: "Shape tool")
            }
        }

        var symbolName: String {
            switch self {
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// Normalized composition-space endpoints.
    var start: CGPoint
    var end: CGPoint
    var color: RGBAColor
    /// Fraction of the composition's smaller dimension.
    var lineWidth: Double
    var isFilled: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        start: CGPoint,
        end: CGPoint,
        color: RGBAColor = RGBAColor(red: 1, green: 0.27, blue: 0.23),
        lineWidth: Double = 0.008,
        isFilled: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
        self.isFilled = isFilled
    }

    var boundingBox: CGRect {
        CGRect(
            x: Swift.min(start.x, end.x),
            y: Swift.min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

/// Freehand drawing plus the vector shapes that sit alongside it.
///
/// PencilKit owns the freehand strokes and serialises them to `pencilData`,
/// which keeps them editable — reopening the drawing tool restores the exact
/// stroke set rather than a flattened bitmap.
struct DrawingOverlay: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// `PKDrawing.dataRepresentation()`.
    var pencilData: Data
    var shapes: [VectorShape]
    var timeRange: TimeRange?
    var opacity: Double

    init(
        id: UUID = UUID(),
        pencilData: Data = Data(),
        shapes: [VectorShape] = [],
        timeRange: TimeRange? = nil,
        opacity: Double = 1
    ) {
        self.id = id
        self.pencilData = pencilData
        self.shapes = shapes
        self.timeRange = timeRange
        self.opacity = opacity
    }

    var isEmpty: Bool { pencilData.isEmpty && shapes.isEmpty }

    func isVisible(at time: TimeInterval) -> Bool {
        guard let timeRange else { return true }
        return timeRange.contains(time)
    }
}
