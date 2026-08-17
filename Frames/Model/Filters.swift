import Foundation

/// How a filter is applied on top of whatever else is in the pipeline.
///
/// A filter is a *recipe of primitives*, not an opaque LUT. That means the
/// preview and the export share one implementation, filters compose predictably
/// with the user's own adjustments, and intensity is a real interpolation
/// rather than a cross-fade between two rendered images.
struct FilterRecipe: Hashable, Sendable, Codable {
    /// Base grade, expressed in the same vocabulary as the Adjust tool.
    var adjustments: AdjustmentSet
    /// Per-channel gain, applied after the grade. 1 is neutral.
    var channelGain: RGBAColor
    /// Per-channel lift (added to shadows). 0 is neutral.
    var channelLift: RGBAColor
    /// Tone curve control points in 0...1, evaluated as a monotone spline.
    var toneCurve: [Double]
    /// Colour pushed into the shadows and highlights respectively.
    var shadowTint: RGBAColor
    var highlightTint: RGBAColor
    var splitToneStrength: Double
    var isMonochrome: Bool
    var bloom: Double

    init(
        adjustments: AdjustmentSet = AdjustmentSet(),
        channelGain: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1),
        channelLift: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0),
        toneCurve: [Double] = [0, 0.25, 0.5, 0.75, 1],
        shadowTint: RGBAColor = .clear,
        highlightTint: RGBAColor = .clear,
        splitToneStrength: Double = 0,
        isMonochrome: Bool = false,
        bloom: Double = 0
    ) {
        self.adjustments = adjustments
        self.channelGain = channelGain
        self.channelLift = channelLift
        self.toneCurve = toneCurve
        self.shadowTint = shadowTint
        self.highlightTint = highlightTint
        self.splitToneStrength = splitToneStrength
        self.isMonochrome = isMonochrome
        self.bloom = bloom
    }

    static let neutral = FilterRecipe()

    var isNeutral: Bool { self == .neutral }
}

enum FilterCategory: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case natural
    case film
    case cinematic
    case monochrome
    case creative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .natural: String(localized: "Natural", comment: "Filter category")
        case .film: String(localized: "Film", comment: "Filter category")
        case .cinematic: String(localized: "Cinematic", comment: "Filter category")
        case .monochrome: String(localized: "Black & White", comment: "Filter category")
        case .creative: String(localized: "Creative", comment: "Filter category")
        }
    }
}

/// A named grade the user can pick from the Filters strip.
struct FilterPreset: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let category: FilterCategory
    let recipe: FilterRecipe
}

/// The user's choice of filter, stored in the document.
///
/// Only the identifier and intensity are persisted — the recipe itself lives in
/// code, so improving a filter improves every existing session rather than
/// baking yesterday's numbers into the file.
struct FilterInstance: Codable, Hashable, Sendable {
    var presetID: String
    var intensity: Double

    init(presetID: String, intensity: Double = 1) {
        self.presetID = presetID
        self.intensity = min(max(intensity, 0), 1)
    }

    var preset: FilterPreset? { FilterCatalog.preset(id: presetID) }
}

/// The shipped filter set.
///
/// Curated rather than exhaustive: every entry here is a grade someone would
/// actually finish an edit with, and each is built from the same primitives the
/// Adjust tool exposes, so nothing in the catalogue can do something the render
/// engine can't reproduce on export.
enum FilterCatalog {
    static let none = FilterPreset(
        id: "none",
        displayName: String(localized: "Original", comment: "Filter name"),
        category: .natural,
        recipe: .neutral
    )

    static let all: [FilterPreset] = [
        // MARK: Natural
        FilterPreset(
            id: "clean", displayName: String(localized: "Clean", comment: "Filter name"),
            category: .natural,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.10, .definition: 0.18, .saturation: 0.05]),
                toneCurve: [0, 0.24, 0.5, 0.77, 1]
            )
        ),
        FilterPreset(
            id: "warm", displayName: String(localized: "Warm", comment: "Filter name"),
            category: .natural,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.warmth: 0.28, .vibrance: 0.16, .contrast: 0.06]),
                channelGain: RGBAColor(red: 1.04, green: 1.0, blue: 0.95)
            )
        ),
        FilterPreset(
            id: "cool", displayName: String(localized: "Cool", comment: "Filter name"),
            category: .natural,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.warmth: -0.26, .vibrance: 0.12, .contrast: 0.08]),
                channelGain: RGBAColor(red: 0.96, green: 1.0, blue: 1.05)
            )
        ),
        FilterPreset(
            id: "soft", displayName: String(localized: "Soft", comment: "Filter name"),
            category: .natural,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: -0.12, .shadows: 0.18, .smoothness: 0.20, .fade: 0.10]),
                toneCurve: [0.03, 0.27, 0.5, 0.74, 0.97]
            )
        ),
        FilterPreset(
            id: "bright", displayName: String(localized: "Bright", comment: "Filter name"),
            category: .natural,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.exposure: 0.14, .brilliance: 0.24, .highlights: -0.10, .saturation: 0.08])
            )
        ),

        // MARK: Film
        FilterPreset(
            id: "film01", displayName: String(localized: "Film 01", comment: "Filter name"),
            category: .film,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.14, .saturation: -0.08, .grain: 0.22, .fade: 0.12]),
                channelLift: RGBAColor(red: 0.02, green: 0.015, blue: 0.03),
                toneCurve: [0.04, 0.26, 0.5, 0.76, 0.96]
            )
        ),
        FilterPreset(
            id: "film02", displayName: String(localized: "Film 02", comment: "Filter name"),
            category: .film,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.warmth: 0.16, .contrast: 0.10, .grain: 0.28, .vignette: 0.16]),
                channelGain: RGBAColor(red: 1.03, green: 0.99, blue: 0.94),
                shadowTint: RGBAColor(red: 0.12, green: 0.10, blue: 0.05),
                splitToneStrength: 0.35
            )
        ),
        FilterPreset(
            id: "film03", displayName: String(localized: "Film 03", comment: "Filter name"),
            category: .film,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.warmth: -0.12, .saturation: -0.14, .grain: 0.20, .definition: 0.12]),
                channelGain: RGBAColor(red: 0.97, green: 1.0, blue: 1.03),
                shadowTint: RGBAColor(red: 0.04, green: 0.08, blue: 0.14),
                splitToneStrength: 0.30
            )
        ),
        FilterPreset(
            id: "faded", displayName: String(localized: "Faded", comment: "Filter name"),
            category: .film,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.fade: 0.42, .contrast: -0.10, .saturation: -0.18, .grain: 0.12]),
                channelLift: RGBAColor(red: 0.05, green: 0.05, blue: 0.055),
                toneCurve: [0.08, 0.30, 0.52, 0.74, 0.93]
            )
        ),
        FilterPreset(
            id: "vintage", displayName: String(localized: "Vintage", comment: "Filter name"),
            category: .film,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.warmth: 0.32, .saturation: -0.22, .vignette: 0.28, .grain: 0.24, .fade: 0.20]),
                channelGain: RGBAColor(red: 1.06, green: 0.98, blue: 0.88),
                shadowTint: RGBAColor(red: 0.14, green: 0.09, blue: 0.03),
                highlightTint: RGBAColor(red: 0.16, green: 0.12, blue: 0.04),
                splitToneStrength: 0.45
            )
        ),

        // MARK: Cinematic
        FilterPreset(
            id: "warmCinema", displayName: String(localized: "Warm Cinema", comment: "Filter name"),
            category: .cinematic,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.18, .shadows: -0.12, .warmth: 0.14, .definition: 0.14]),
                toneCurve: [0, 0.20, 0.48, 0.79, 1],
                shadowTint: RGBAColor(red: 0.02, green: 0.06, blue: 0.12),
                highlightTint: RGBAColor(red: 0.16, green: 0.10, blue: 0.02),
                splitToneStrength: 0.55
            )
        ),
        FilterPreset(
            id: "coldCinema", displayName: String(localized: "Cold Cinema", comment: "Filter name"),
            category: .cinematic,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.20, .warmth: -0.22, .saturation: -0.10, .definition: 0.16]),
                channelGain: RGBAColor(red: 0.94, green: 0.99, blue: 1.07),
                shadowTint: RGBAColor(red: 0.02, green: 0.07, blue: 0.16),
                splitToneStrength: 0.50
            )
        ),
        FilterPreset(
            id: "dramatic", displayName: String(localized: "Dramatic", comment: "Filter name"),
            category: .cinematic,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.34, .blackPoint: 0.22, .highlights: -0.16, .definition: 0.26, .vignette: 0.18]),
                toneCurve: [0, 0.17, 0.47, 0.82, 1]
            )
        ),
        FilterPreset(
            id: "dark", displayName: String(localized: "Dark", comment: "Filter name"),
            category: .cinematic,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.exposure: -0.14, .shadows: -0.24, .blackPoint: 0.26, .saturation: -0.08, .vignette: 0.26])
            )
        ),
        FilterPreset(
            id: "golden", displayName: String(localized: "Golden", comment: "Filter name"),
            category: .cinematic,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.warmth: 0.34, .vibrance: 0.22, .highlights: -0.14, .contrast: 0.12]),
                channelGain: RGBAColor(red: 1.08, green: 1.0, blue: 0.86),
                highlightTint: RGBAColor(red: 0.22, green: 0.14, blue: 0.0),
                splitToneStrength: 0.40
            )
        ),

        // MARK: Black & White
        FilterPreset(
            id: "mono", displayName: String(localized: "Mono", comment: "Filter name"),
            category: .monochrome,
            recipe: FilterRecipe(adjustments: AdjustmentSet([.contrast: 0.08]), isMonochrome: true)
        ),
        FilterPreset(
            id: "noir", displayName: String(localized: "Noir", comment: "Filter name"),
            category: .monochrome,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.38, .blackPoint: 0.30, .definition: 0.20, .vignette: 0.30]),
                toneCurve: [0, 0.14, 0.46, 0.84, 1],
                isMonochrome: true
            )
        ),
        FilterPreset(
            id: "silver", displayName: String(localized: "Silver", comment: "Filter name"),
            category: .monochrome,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.brilliance: 0.24, .highlights: -0.12, .shadows: 0.14, .grain: 0.10]),
                channelLift: RGBAColor(red: 0.03, green: 0.03, blue: 0.035),
                isMonochrome: true
            )
        ),
        FilterPreset(
            id: "monoContrast", displayName: String(localized: "Contrast", comment: "Filter name"),
            category: .monochrome,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.52, .definition: 0.30, .blackPoint: 0.18]),
                toneCurve: [0, 0.12, 0.44, 0.86, 1],
                isMonochrome: true
            )
        ),

        // MARK: Creative
        FilterPreset(
            id: "dream", displayName: String(localized: "Dream", comment: "Filter name"),
            category: .creative,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.smoothness: 0.34, .fade: 0.22, .vibrance: 0.18, .contrast: -0.08]),
                highlightTint: RGBAColor(red: 0.14, green: 0.10, blue: 0.20),
                splitToneStrength: 0.35,
                bloom: 0.45
            )
        ),
        FilterPreset(
            id: "pastel", displayName: String(localized: "Pastel", comment: "Filter name"),
            category: .creative,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.saturation: -0.18, .fade: 0.28, .brilliance: 0.20, .highlights: -0.10]),
                channelLift: RGBAColor(red: 0.06, green: 0.05, blue: 0.07),
                toneCurve: [0.07, 0.31, 0.53, 0.75, 0.95]
            )
        ),
        FilterPreset(
            id: "retro", displayName: String(localized: "Retro", comment: "Filter name"),
            category: .creative,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.warmth: 0.20, .saturation: 0.14, .contrast: 0.16, .grain: 0.18, .vignette: 0.20]),
                channelGain: RGBAColor(red: 1.05, green: 0.97, blue: 0.92),
                shadowTint: RGBAColor(red: 0.10, green: 0.02, blue: 0.08),
                highlightTint: RGBAColor(red: 0.14, green: 0.11, blue: 0.02),
                splitToneStrength: 0.50
            )
        ),
        FilterPreset(
            id: "chrome", displayName: String(localized: "Chrome", comment: "Filter name"),
            category: .creative,
            recipe: FilterRecipe(
                adjustments: AdjustmentSet([.contrast: 0.24, .saturation: 0.26, .definition: 0.22, .brilliance: 0.16]),
                channelGain: RGBAColor(red: 1.02, green: 1.0, blue: 1.03),
                toneCurve: [0, 0.21, 0.5, 0.80, 1]
            )
        )
    ]

    static func preset(id: String) -> FilterPreset? {
        if id == none.id { return none }
        return all.first { $0.id == id }
    }

    static func presets(in category: FilterCategory) -> [FilterPreset] {
        all.filter { $0.category == category }
    }
}
