import Foundation

enum EffectCategory: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case basic
    case motion
    case film
    case retro
    case creative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .basic: String(localized: "Basic", comment: "Effect category")
        case .motion: String(localized: "Motion", comment: "Effect category")
        case .film: String(localized: "Film", comment: "Effect category")
        case .retro: String(localized: "Retro", comment: "Effect category")
        case .creative: String(localized: "Creative", comment: "Effect category")
        }
    }
}

/// The shipped effects.
///
/// Every case here is implemented in `EffectRenderer` and applies identically
/// in the preview and in the export. Nothing appears in this list that the
/// render engine cannot draw.
enum EffectKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    // Basic
    case bloom
    case glow
    case softBlur
    case sharpen
    // Motion
    case motionBlur
    case shake
    case zoom
    // Film
    case grain
    case lightLeak
    case fadedFilm
    // Retro
    case vhs
    case scanlines
    case chromaticShift
    // Creative
    case dream
    case softLight

    var id: String { rawValue }

    var category: EffectCategory {
        switch self {
        case .bloom, .glow, .softBlur, .sharpen: .basic
        case .motionBlur, .shake, .zoom: .motion
        case .grain, .lightLeak, .fadedFilm: .film
        case .vhs, .scanlines, .chromaticShift: .retro
        case .dream, .softLight: .creative
        }
    }

    var displayName: String {
        switch self {
        case .bloom: String(localized: "Bloom", comment: "Effect")
        case .glow: String(localized: "Glow", comment: "Effect")
        case .softBlur: String(localized: "Soft Blur", comment: "Effect")
        case .sharpen: String(localized: "Sharpen", comment: "Effect")
        case .motionBlur: String(localized: "Motion Blur", comment: "Effect")
        case .shake: String(localized: "Shake", comment: "Effect")
        case .zoom: String(localized: "Zoom", comment: "Effect")
        case .grain: String(localized: "Grain", comment: "Effect")
        case .lightLeak: String(localized: "Light Leak", comment: "Effect")
        case .fadedFilm: String(localized: "Faded Film", comment: "Effect")
        case .vhs: String(localized: "VHS", comment: "Effect")
        case .scanlines: String(localized: "Scanlines", comment: "Effect")
        case .chromaticShift: String(localized: "Chromatic Shift", comment: "Effect")
        case .dream: String(localized: "Dream", comment: "Effect")
        case .softLight: String(localized: "Soft Light", comment: "Effect")
        }
    }

    var symbolName: String {
        switch self {
        case .bloom: "sparkles"
        case .glow: "sun.max.fill"
        case .softBlur: "drop.halffull"
        case .sharpen: "triangle.fill"
        case .motionBlur: "wind"
        case .shake: "waveform.path"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .grain: "circle.grid.3x3.fill"
        case .lightLeak: "flashlight.on.fill"
        case .fadedFilm: "film"
        case .vhs: "tv"
        case .scanlines: "lines.measurement.horizontal"
        case .chromaticShift: "circle.hexagongrid.fill"
        case .dream: "cloud.fill"
        case .softLight: "light.max"
        }
    }

    /// Effects whose output changes over time. Stills get a fixed sample of
    /// these rather than nothing, so the same effect list works for photos.
    var isTemporal: Bool {
        switch self {
        case .motionBlur, .shake, .zoom, .vhs, .lightLeak: true
        default: false
        }
    }

    var defaultIntensity: Double {
        switch self {
        case .sharpen, .grain, .scanlines, .chromaticShift: 0.35
        case .shake, .zoom: 0.3
        default: 0.5
        }
    }
}

/// One effect the user has added, with its intensity and optional time range.
struct EffectInstance: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: EffectKind
    var intensity: Double
    var timeRange: TimeRange?
    var keyframes: KeyframeSet

    init(
        id: UUID = UUID(),
        kind: EffectKind,
        intensity: Double? = nil,
        timeRange: TimeRange? = nil,
        keyframes: KeyframeSet = KeyframeSet()
    ) {
        self.id = id
        self.kind = kind
        self.intensity = min(max(intensity ?? kind.defaultIntensity, 0), 1)
        self.timeRange = timeRange
        self.keyframes = keyframes
    }

    func intensity(at time: TimeInterval) -> Double {
        min(max(keyframes.value(.effectIntensity, at: time, fallback: intensity), 0), 1)
    }

    func isActive(at time: TimeInterval) -> Bool {
        guard let timeRange else { return true }
        return timeRange.contains(time)
    }
}

/// A transition between two adjacent clips.
enum TransitionKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case none
    case dissolve
    case fadeThroughBlack
    case fadeThroughWhite
    case slide
    case blur
    case zoom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: String(localized: "None", comment: "Transition")
        case .dissolve: String(localized: "Dissolve", comment: "Transition")
        case .fadeThroughBlack: String(localized: "Fade to Black", comment: "Transition")
        case .fadeThroughWhite: String(localized: "Fade to White", comment: "Transition")
        case .slide: String(localized: "Slide", comment: "Transition")
        case .blur: String(localized: "Blur", comment: "Transition")
        case .zoom: String(localized: "Zoom", comment: "Transition")
        }
    }

    var symbolName: String {
        switch self {
        case .none: "minus"
        case .dissolve: "square.on.square.intersection.dashed"
        case .fadeThroughBlack: "circle.lefthalf.filled"
        case .fadeThroughWhite: "circle.righthalf.filled"
        case .slide: "arrow.left.arrow.right"
        case .blur: "drop.halffull"
        case .zoom: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// A transition attached to the *start* of a clip, overlapping the clip before
/// it. Storing it on one side keeps the timeline math unambiguous.
struct Transition: Codable, Hashable, Sendable {
    var kind: TransitionKind
    var duration: TimeInterval

    init(kind: TransitionKind = .none, duration: TimeInterval = 0.5) {
        self.kind = kind
        self.duration = max(0, duration)
    }

    static let none = Transition()

    var isActive: Bool { kind != .none && duration > 0 }
}
