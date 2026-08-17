import Foundation

/// A single adjustable parameter.
///
/// Every parameter is normalized to a symmetric range around a neutral default
/// so the UI can present one slider design for all of them, and so "reset"
/// always means "return to `defaultValue`". The render engine is responsible
/// for mapping these normalized values onto the filter inputs they drive.
enum AdjustmentParameter: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    // Light
    case exposure
    case brilliance
    case highlights
    case shadows
    case brightness
    case contrast
    case blackPoint
    // Color
    case saturation
    case vibrance
    case warmth
    case tint
    // Detail
    case sharpness
    case definition
    case noiseReduction
    case smoothness
    case grain
    // Finishing
    case fade
    case vignette

    var id: String { rawValue }

    var group: AdjustmentGroup {
        switch self {
        case .exposure, .brilliance, .highlights, .shadows, .brightness, .contrast, .blackPoint:
            .light
        case .saturation, .vibrance, .warmth, .tint:
            .color
        case .sharpness, .definition, .noiseReduction, .smoothness, .grain:
            .detail
        case .fade, .vignette:
            .finishing
        }
    }

    /// Parameters that only make sense as an increase from zero (there is no
    /// such thing as negative grain) use a 0...1 range; the rest are bipolar.
    var range: ClosedRange<Double> {
        switch self {
        case .sharpness, .definition, .noiseReduction, .smoothness, .grain, .fade:
            0...1
        case .vignette:
            -1...1
        default:
            -1...1
        }
    }

    var defaultValue: Double { 0 }

    var displayName: String {
        switch self {
        case .exposure: String(localized: "Exposure", comment: "Adjustment")
        case .brilliance: String(localized: "Brilliance", comment: "Adjustment")
        case .highlights: String(localized: "Highlights", comment: "Adjustment")
        case .shadows: String(localized: "Shadows", comment: "Adjustment")
        case .brightness: String(localized: "Brightness", comment: "Adjustment")
        case .contrast: String(localized: "Contrast", comment: "Adjustment")
        case .blackPoint: String(localized: "Black Point", comment: "Adjustment")
        case .saturation: String(localized: "Saturation", comment: "Adjustment")
        case .vibrance: String(localized: "Vibrance", comment: "Adjustment")
        case .warmth: String(localized: "Warmth", comment: "Adjustment")
        case .tint: String(localized: "Tint", comment: "Adjustment")
        case .sharpness: String(localized: "Sharpness", comment: "Adjustment")
        case .definition: String(localized: "Definition", comment: "Adjustment")
        case .noiseReduction: String(localized: "Noise Reduction", comment: "Adjustment")
        case .smoothness: String(localized: "Smoothness", comment: "Adjustment")
        case .grain: String(localized: "Grain", comment: "Adjustment")
        case .fade: String(localized: "Fade", comment: "Adjustment")
        case .vignette: String(localized: "Vignette", comment: "Adjustment")
        }
    }

    var symbolName: String {
        switch self {
        case .exposure: "plusminus.circle"
        case .brilliance: "sun.max"
        case .highlights: "circle.lefthalf.filled.inverse"
        case .shadows: "circle.righthalf.filled"
        case .brightness: "sun.min"
        case .contrast: "circle.lefthalf.filled"
        case .blackPoint: "circle.fill"
        case .saturation: "drop.fill"
        case .vibrance: "drop"
        case .warmth: "thermometer.medium"
        case .tint: "eyedropper.halffull"
        case .sharpness: "triangle"
        case .definition: "square.stack.3d.up"
        case .noiseReduction: "wand.and.sparkles"
        case .smoothness: "aqi.medium"
        case .grain: "circle.grid.3x3"
        case .fade: "square.filled.on.square"
        case .vignette: "circle.dashed"
        }
    }

    /// Displayed next to the slider. Percentages read better than raw floats
    /// for everything here.
    func formattedValue(_ value: Double) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)" : "\(percent)"
    }
}

enum AdjustmentGroup: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case light
    case color
    case detail
    case finishing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: String(localized: "Light", comment: "Adjustment group")
        case .color: String(localized: "Color", comment: "Adjustment group")
        case .detail: String(localized: "Detail", comment: "Adjustment group")
        case .finishing: String(localized: "Finishing", comment: "Adjustment group")
        }
    }

    var parameters: [AdjustmentParameter] {
        AdjustmentParameter.allCases.filter { $0.group == self }
    }
}

/// A sparse set of adjustment values.
///
/// Only parameters that differ from their default are stored, which keeps the
/// session file small, makes `isIdentity` free, and lets the render engine skip
/// entire filter stages when nothing in a stage is active.
struct AdjustmentSet: Codable, Hashable, Sendable {
    private var storage: [String: Double]

    init() {
        storage = [:]
    }

    init(_ values: [AdjustmentParameter: Double]) {
        storage = [:]
        for (parameter, value) in values {
            self[parameter] = value
        }
    }

    subscript(parameter: AdjustmentParameter) -> Double {
        get { storage[parameter.rawValue] ?? parameter.defaultValue }
        set {
            let range = parameter.range
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            if abs(clamped - parameter.defaultValue) < 0.0005 {
                storage.removeValue(forKey: parameter.rawValue)
            } else {
                storage[parameter.rawValue] = clamped
            }
        }
    }

    var isIdentity: Bool { storage.isEmpty }

    /// Parameters the user has actually moved, in canonical order.
    var activeParameters: [AdjustmentParameter] {
        AdjustmentParameter.allCases.filter { storage[$0.rawValue] != nil }
    }

    func isActive(_ parameter: AdjustmentParameter) -> Bool {
        storage[parameter.rawValue] != nil
    }

    mutating func reset(_ parameter: AdjustmentParameter) {
        storage.removeValue(forKey: parameter.rawValue)
    }

    mutating func resetAll() {
        storage.removeAll()
    }

    /// Scales every active value, used for filter intensity and for fading an
    /// adjustment set in and out of a mask.
    func scaled(by factor: Double) -> AdjustmentSet {
        var copy = AdjustmentSet()
        for (key, value) in storage {
            copy.storage[key] = value * factor
        }
        return copy
    }

    /// Combines two sets additively, clamped to each parameter's range.
    func merging(_ other: AdjustmentSet) -> AdjustmentSet {
        var copy = self
        for parameter in AdjustmentParameter.allCases where other.isActive(parameter) {
            copy[parameter] = copy[parameter] + other[parameter]
        }
        return copy
    }

    /// Linear interpolation, used by keyframed adjustments.
    static func interpolate(_ a: AdjustmentSet, _ b: AdjustmentSet, t: Double) -> AdjustmentSet {
        let clampedT = min(max(t, 0), 1)
        var result = AdjustmentSet()
        for parameter in AdjustmentParameter.allCases {
            let value = a[parameter] + (b[parameter] - a[parameter]) * clampedT
            if abs(value - parameter.defaultValue) > 0.0005 {
                result[parameter] = value
            }
        }
        return result
    }
}
