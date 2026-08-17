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
        smoothing: Double = 0.7,
        detailPreservation: Double = 0.6,
        lowLight: Double = 0.5,
        colorNoiseReduction: Double = 0.55,
        glow: Double = 0.28,
        evenness: Double = 0.5,
        warmth: Double = 0.2,
        temporalStability: Double = 0.7,
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

        var settings: PortraitSettings {
            switch self {
            case .natural:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.42, detailPreservation: 0.75,
                    lowLight: 0.25, colorNoiseReduction: 0.35, glow: 0.15,
                    evenness: 0.3, warmth: 0.12, temporalStability: 0.65
                )
            case .clean:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.72, detailPreservation: 0.6,
                    lowLight: 0.45, colorNoiseReduction: 0.55, glow: 0.28,
                    evenness: 0.55, warmth: 0.2, temporalStability: 0.7
                )
            case .studio:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.88, detailPreservation: 0.52,
                    lowLight: 0.4, colorNoiseReduction: 0.6, glow: 0.45,
                    evenness: 0.7, warmth: 0.26, temporalStability: 0.78
                )
            case .lowLight:
                PortraitSettings(
                    isEnabled: true, smoothing: 0.7, detailPreservation: 0.58,
                    lowLight: 0.85, colorNoiseReduction: 0.8, glow: 0.22,
                    evenness: 0.6, warmth: 0.24, temporalStability: 0.85
                )
            }
        }
    }

    /// The preset this matches, if the user has not since moved a slider.
    var matchingPreset: Preset? {
        Preset.allCases.first { $0.settings == self }
    }
}
