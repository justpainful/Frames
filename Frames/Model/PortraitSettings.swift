import Foundation

/// The Portrait mode: clean skin, low noise, real structure.
///
/// This is not a beauty filter and not a blur. The problem it solves is that
/// indoor and low-light footage arrives with sensor noise, camera sharpening
/// and micro-texture all amplifying each other on skin, and the usual fixes —
/// raise exposure, then smooth — make both worse. Frames treats it as one
/// system: denoise before the shadows are lifted, separate surface texture from
/// structural detail, suppress the former hard, put the latter back, and keep
/// the result stable frame to frame.
///
/// What it must never do: change anyone's shape. No reshaping, no slimming, no
/// moving a body outline. It changes how existing light and texture read, not
/// what the person is.
struct PortraitSettings: Codable, Hashable, Sendable {
    /// Off by default. Portrait is a deliberate choice, not something that
    /// happens to footage without asking.
    var isEnabled: Bool

    /// How hard surface texture — pores, grain, micro-roughness — is
    /// suppressed. High values must still leave the skin's light and colour
    /// gradients intact, or it stops reading as skin.
    var smoothing: Double

    /// How much structural detail is put back after smoothing: body outlines,
    /// hair, eyes, lips, brows, fabric, finger edges.
    var detailPreservation: Double

    /// Shadow recovery paired with denoise, for footage shot darker than it
    /// should have been.
    var lowLight: Double

    /// Chroma noise cleanup, which is what makes dark areas stop looking
    /// blotchy.
    var colorNoiseReduction: Double

    /// Highlight diffusion. Softens strong highlights and the transition around
    /// them; must not become a white haze over the frame.
    var glow: Double

    /// Evens out tonal patchiness across skin without flattening it.
    var evenness: Double

    /// Protects and gently warms skin tones so denoise does not leave them grey.
    var warmth: Double

    /// How strongly the result is held steady between frames. This is what
    /// stops the smoothing amount, exposure and mask edges from flickering
    /// during motion.
    var temporalStability: Double

    /// Restricts the strongest processing to detected people, so the background
    /// is not softened for no reason.
    var restrictToPeople: Bool

    init(
        isEnabled: Bool = false,
        smoothing: Double = 0.52,
        detailPreservation: Double = 0.70,
        lowLight: Double = 0.45,
        colorNoiseReduction: Double = 0.55,
        glow: Double = 0.08,
        evenness: Double = 0.30,
        warmth: Double = 0.05,
        temporalStability: Double = 0.75,
        restrictToPeople: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.smoothing = min(max(smoothing, 0), 1)
        self.detailPreservation = min(max(detailPreservation, 0), 1)
        self.lowLight = min(max(lowLight, 0), 1)
        self.colorNoiseReduction = min(max(colorNoiseReduction, 0), 1)
        self.glow = min(max(glow, 0), 1)
        self.evenness = min(max(evenness, 0), 1)
        self.warmth = min(max(warmth, 0), 1)
        self.temporalStability = min(max(temporalStability, 0), 1)
        self.restrictToPeople = restrictToPeople
    }

    static let off = PortraitSettings()

    var isActive: Bool { isEnabled }

    /// True when the settings need a person mask from Vision.
    var needsPersonMask: Bool { isEnabled && restrictToPeople }

    // MARK: - Presets

    enum Preset: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        case natural
        case clean
        case studio
        case lowLight

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .natural: String(localized: "Natural", comment: "Portrait preset")
            case .clean: String(localized: "Clean", comment: "Portrait preset")
            case .studio: String(localized: "Studio", comment: "Portrait preset")
            case .lowLight: String(localized: "Low Light", comment: "Portrait preset")
            }
        }

        var detail: String {
            switch self {
            case .natural:
                String(localized: "A light pass. Keeps most texture.", comment: "Portrait preset detail")
            case .clean:
                String(localized: "Smooth, even skin with detail kept.", comment: "Portrait preset detail")
            case .studio:
                String(localized: "Very smooth, with soft highlights.", comment: "Portrait preset detail")
            case .lowLight:
                String(localized: "For dim rooms. Cleans noise first.", comment: "Portrait preset detail")
            }
        }

        /// The numbers are lower than they look like they should be, on purpose.
        ///
        /// Because the cosmetic stages are now confined to skin, the same
        /// smoothing value does much more visible work than it did when it was
        /// spread across the whole frame — and the failure mode of this feature
        /// is not "too subtle", it is "obviously a filter". Glow and warmth in
        /// particular are kept near zero by default: a global colour cast and a
        /// screened highlight bloom are the two things that read as an overlay
        /// faster than anything else.
        var settings: PortraitSettings {
            switch self {
            case .natural:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.30, detailPreservation: 0.82,
                    lowLight: 0.25, colorNoiseReduction: 0.35, glow: 0.04,
                    evenness: 0.18, warmth: 0.03, temporalStability: 0.7
                )
            case .clean:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.52, detailPreservation: 0.70,
                    lowLight: 0.45, colorNoiseReduction: 0.55, glow: 0.08,
                    evenness: 0.30, warmth: 0.05, temporalStability: 0.75
                )
            case .studio:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.70, detailPreservation: 0.62,
                    lowLight: 0.40, colorNoiseReduction: 0.60, glow: 0.16,
                    evenness: 0.42, warmth: 0.08, temporalStability: 0.8
                )
            case .lowLight:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.48, detailPreservation: 0.70,
                    lowLight: 0.85, colorNoiseReduction: 0.80, glow: 0.05,
                    evenness: 0.34, warmth: 0.06, temporalStability: 0.88
                )
            }
        }
    }

    /// The preset this matches, if the user has not since moved a slider.
    var matchingPreset: Preset? {
        Preset.allCases.first { $0.settings == self }
    }
}
