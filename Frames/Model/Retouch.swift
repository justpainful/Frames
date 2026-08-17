import CoreGraphics
import Foundation

/// A single retouch fix applied to one spot.
///
/// Retouch in Frames is deliberately small: correct a blemish, calm a red eye,
/// lift a shadow under an eye. There is no reshaping here and there will not
/// be — these change how a small area *reads*, not what anyone is shaped like.
struct RetouchSpot: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        /// Replaces a small area with the surrounding skin.
        case blemish
        /// Desaturates and darkens the red channel inside the pupil.
        case redEye
        /// Softens and lifts, for shadows under the eyes.
        case brighten

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .blemish: String(localized: "Blemish", comment: "Retouch tool")
            case .redEye: String(localized: "Red-Eye", comment: "Retouch tool")
            case .brighten: String(localized: "Brighten", comment: "Retouch tool")
            }
        }

        var symbolName: String {
            switch self {
            case .blemish: "bandage"
            case .redEye: "eye.trianglebadge.exclamationmark"
            case .brighten: "sun.max"
            }
        }

        var detail: String {
            switch self {
            case .blemish:
                String(localized: "Blends a small spot into the skin around it.",
                       comment: "Retouch tool detail")
            case .redEye:
                String(localized: "Takes the red out of a pupil.", comment: "Retouch tool detail")
            case .brighten:
                String(localized: "Lifts a small shadow.", comment: "Retouch tool detail")
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// Centre in normalized composition space.
    var position: CGPoint
    /// Radius as a fraction of the composition's smaller dimension.
    var radius: Double
    /// 0...1. Defaults are conservative on purpose: retouching that is
    /// immediately obvious has failed.
    var strength: Double

    init(
        id: UUID = UUID(),
        kind: Kind,
        position: CGPoint,
        radius: Double = 0.035,
        strength: Double = 0.75
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.radius = min(max(radius, 0.005), 0.25)
        self.strength = min(max(strength, 0), 1)
    }

    /// Bounding box in normalized composition space.
    var boundingBox: CGRect {
        CGRect(
            x: position.x - radius,
            y: position.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }
}
