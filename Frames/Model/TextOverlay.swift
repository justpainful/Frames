import CoreGraphics
import Foundation

enum TextFontDesign: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case system
    case serif
    case rounded
    case monospaced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "System", comment: "Font design")
        case .serif: String(localized: "Serif", comment: "Font design")
        case .rounded: String(localized: "Rounded", comment: "Font design")
        case .monospaced: String(localized: "Mono", comment: "Font design")
        }
    }
}

enum TextWeight: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: String(localized: "Light", comment: "Font weight")
        case .regular: String(localized: "Regular", comment: "Font weight")
        case .medium: String(localized: "Medium", comment: "Font weight")
        case .semibold: String(localized: "Semibold", comment: "Font weight")
        case .bold: String(localized: "Bold", comment: "Font weight")
        case .heavy: String(localized: "Heavy", comment: "Font weight")
        }
    }

    /// CoreText weight value, used when the render engine builds the font.
    var coreTextWeight: CGFloat {
        switch self {
        case .light: -0.4
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        }
    }
}

enum TextAlignmentChoice: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
}

/// A drop shadow, shared by text and image overlays.
struct ShadowStyle: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var color: RGBAColor
    /// Normalized to the composition's smaller dimension.
    var radius: Double
    var offsetX: Double
    var offsetY: Double
    var opacity: Double

    init(
        isEnabled: Bool = false,
        color: RGBAColor = .black,
        radius: Double = 0.012,
        offsetX: Double = 0,
        offsetY: Double = 0.006,
        opacity: Double = 0.5
    ) {
        self.isEnabled = isEnabled
        self.color = color
        self.radius = radius
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.opacity = opacity
    }

    static let none = ShadowStyle()
}

/// A plate drawn behind text.
struct TextBackgroundStyle: Codable, Hashable, Sendable {
    enum Shape: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        case none
        case plate
        case perLine
        case underline

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: String(localized: "None", comment: "Text background")
            case .plate: String(localized: "Plate", comment: "Text background")
            case .perLine: String(localized: "Per Line", comment: "Text background")
            case .underline: String(localized: "Underline", comment: "Text background")
            }
        }
    }

    var shape: Shape
    var color: RGBAColor
    var cornerRadius: Double
    var padding: Double

    init(
        shape: Shape = .none,
        color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55),
        cornerRadius: Double = 0.02,
        padding: Double = 0.014
    ) {
        self.shape = shape
        self.color = color
        self.cornerRadius = cornerRadius
        self.padding = padding
    }
}

struct TextStrokeStyle: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var color: RGBAColor
    var width: Double

    init(isEnabled: Bool = false, color: RGBAColor = .black, width: Double = 0.004) {
        self.isEnabled = isEnabled
        self.color = color
        self.width = width
    }
}

/// Everything about how a text layer looks.
struct TextStyle: Codable, Hashable, Sendable {
    var design: TextFontDesign
    /// A specific installed font family, or `nil` for the system font.
    var fontFamily: String?
    /// Cap height as a fraction of the composition height, so text keeps its
    /// relative size regardless of export resolution.
    var fontSize: Double
    var weight: TextWeight
    var isItalic: Bool
    var color: RGBAColor
    var alignment: TextAlignmentChoice
    /// Letter spacing as a fraction of font size.
    var tracking: Double
    /// Line height multiplier.
    var lineSpacing: Double
    var background: TextBackgroundStyle
    var stroke: TextStrokeStyle
    var shadow: ShadowStyle

    init(
        design: TextFontDesign = .system,
        fontFamily: String? = nil,
        fontSize: Double = 0.075,
        weight: TextWeight = .semibold,
        isItalic: Bool = false,
        color: RGBAColor = .white,
        alignment: TextAlignmentChoice = .center,
        tracking: Double = 0,
        lineSpacing: Double = 1.1,
        background: TextBackgroundStyle = TextBackgroundStyle(),
        stroke: TextStrokeStyle = TextStrokeStyle(),
        shadow: ShadowStyle = ShadowStyle(isEnabled: true)
    ) {
        self.design = design
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.weight = weight
        self.isItalic = isItalic
        self.color = color
        self.alignment = alignment
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.background = background
        self.stroke = stroke
        self.shadow = shadow
    }
}

enum TextAnimationIn: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case fade
    case scale
    case slide
    case pop
    case blur

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: String(localized: "None", comment: "Text animation")
        case .fade: String(localized: "Fade", comment: "Text animation")
        case .scale: String(localized: "Scale", comment: "Text animation")
        case .slide: String(localized: "Slide", comment: "Text animation")
        case .pop: String(localized: "Pop", comment: "Text animation")
        case .blur: String(localized: "Blur", comment: "Text animation")
        }
    }
}

enum TextAnimationLoop: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case float
    case pulse

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: String(localized: "None", comment: "Text animation")
        case .float: String(localized: "Float", comment: "Text animation")
        case .pulse: String(localized: "Pulse", comment: "Text animation")
        }
    }
}

enum TextAnimationOut: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case fade
    case shrink
    case slide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: String(localized: "None", comment: "Text animation")
        case .fade: String(localized: "Fade", comment: "Text animation")
        case .shrink: String(localized: "Shrink", comment: "Text animation")
        case .slide: String(localized: "Slide", comment: "Text animation")
        }
    }
}

struct TextAnimationSet: Codable, Hashable, Sendable {
    var entrance: TextAnimationIn
    var loop: TextAnimationLoop
    var exit: TextAnimationOut
    var entranceDuration: TimeInterval
    var exitDuration: TimeInterval

    init(
        entrance: TextAnimationIn = .none,
        loop: TextAnimationLoop = .none,
        exit: TextAnimationOut = .none,
        entranceDuration: TimeInterval = 0.4,
        exitDuration: TimeInterval = 0.4
    ) {
        self.entrance = entrance
        self.loop = loop
        self.exit = exit
        self.entranceDuration = entranceDuration
        self.exitDuration = exitDuration
    }

    var isAnimated: Bool { entrance != .none || loop != .none || exit != .none }
}

/// A text layer.
struct TextOverlay: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var string: String
    var style: TextStyle
    var transform: LayerTransform
    /// `nil` means "for the whole composition", which is what a photo always
    /// gets and what a video text layer gets until the user trims it.
    var timeRange: TimeRange?
    var animation: TextAnimationSet
    var keyframes: KeyframeSet
    /// Maximum line width as a fraction of the composition width, before
    /// wrapping.
    var maximumWidth: Double

    init(
        id: UUID = UUID(),
        string: String = "",
        style: TextStyle = TextStyle(),
        transform: LayerTransform = .identity,
        timeRange: TimeRange? = nil,
        animation: TextAnimationSet = TextAnimationSet(),
        keyframes: KeyframeSet = KeyframeSet(),
        maximumWidth: Double = 0.86
    ) {
        self.id = id
        self.string = string
        self.style = style
        self.transform = transform
        self.timeRange = timeRange
        self.animation = animation
        self.keyframes = keyframes
        self.maximumWidth = maximumWidth
    }

    var isEmpty: Bool { string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func isVisible(at time: TimeInterval) -> Bool {
        guard let timeRange else { return true }
        return timeRange.contains(time)
    }

    /// The opacity and scale multipliers contributed by the in/loop/out
    /// animations at a given moment. Returning this as data keeps the animation
    /// identical in the preview and in the export.
    func animationState(at time: TimeInterval) -> TextAnimationState {
        guard animation.isAnimated, let range = timeRange else { return .identity }
        var state = TextAnimationState.identity

        let elapsed = time - range.start
        let remaining = range.end - time

        if animation.entrance != .none, elapsed < animation.entranceDuration {
            let t = min(max(elapsed / max(animation.entranceDuration, 0.0001), 0), 1)
            let eased = KeyframeEasing.easeOut.apply(t)
            switch animation.entrance {
            case .none: break
            case .fade: state.opacity *= eased
            case .scale: state.opacity *= eased; state.scale *= 0.8 + 0.2 * eased
            case .slide: state.opacity *= eased; state.offsetY += (1 - eased) * 0.06
            case .pop:
                state.opacity *= eased
                let overshoot = sin(eased * .pi) * 0.12
                state.scale *= 0.85 + 0.15 * eased + overshoot
            case .blur: state.opacity *= eased; state.blur += (1 - eased) * 0.5
            }
        }

        if animation.exit != .none, remaining < animation.exitDuration {
            let t = min(max(remaining / max(animation.exitDuration, 0.0001), 0), 1)
            let eased = KeyframeEasing.easeIn.apply(t)
            switch animation.exit {
            case .none: break
            case .fade: state.opacity *= eased
            case .shrink: state.opacity *= eased; state.scale *= 0.9 + 0.1 * eased
            case .slide: state.opacity *= eased; state.offsetY -= (1 - eased) * 0.06
            }
        }

        switch animation.loop {
        case .none: break
        case .float:
            state.offsetY += sin(elapsed * 1.6) * 0.008
        case .pulse:
            state.scale *= 1 + sin(elapsed * 2.4) * 0.025
        }

        return state
    }
}

/// The per-frame result of a text layer's animations.
struct TextAnimationState: Hashable, Sendable {
    var opacity: Double
    var scale: Double
    var offsetX: Double
    var offsetY: Double
    var blur: Double

    static let identity = TextAnimationState(opacity: 1, scale: 1, offsetX: 0, offsetY: 0, blur: 0)
}
