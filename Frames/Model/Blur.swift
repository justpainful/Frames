import Foundation

/// How the blurred pixels are produced.
enum BlurStyle: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case gaussian
    case box
    case disc
    case pixelate
    case mosaic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gaussian: String(localized: "Gaussian", comment: "Blur style")
        case .box: String(localized: "Box", comment: "Blur style")
        case .disc: String(localized: "Disc", comment: "Blur style")
        case .pixelate: String(localized: "Pixelate", comment: "Blur style")
        case .mosaic: String(localized: "Mosaic", comment: "Blur style")
        }
    }

    var symbolName: String {
        switch self {
        case .gaussian: "drop.halffull"
        case .box: "square.on.square.dashed"
        case .disc: "circle.circle"
        case .pixelate: "square.grid.3x3.fill"
        case .mosaic: "square.grid.4x3.fill"
        }
    }

    /// Pixelate and mosaic are quantisers rather than convolutions, so their
    /// strength maps onto a cell size rather than a radius.
    var isQuantiser: Bool {
        self == .pixelate || self == .mosaic
    }
}

/// What the blur is aimed at. This is the first choice the user makes, and it
/// determines which controls appear afterwards.
enum BlurScope: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case full
    case area
    case face
    case person
    case background
    case track

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: String(localized: "Full", comment: "Blur scope")
        case .area: String(localized: "Area", comment: "Blur scope")
        case .face: String(localized: "Face", comment: "Blur scope")
        case .person: String(localized: "Person", comment: "Blur scope")
        case .background: String(localized: "Background", comment: "Blur scope")
        case .track: String(localized: "Track", comment: "Blur scope")
        }
    }

    var symbolName: String {
        switch self {
        case .full: "square.fill"
        case .area: "rectangle.dashed"
        case .face: "face.dashed"
        case .person: "person.fill.viewfinder"
        case .background: "person.and.background.dotted"
        case .track: "dot.viewfinder"
        }
    }

    /// Scopes whose geometry comes from Vision rather than from a drag.
    var requiresDetection: Bool {
        switch self {
        case .face, .person, .background: true
        case .full, .area, .track: false
        }
    }
}

/// One blur the user has added.
///
/// A blur is a mask plus a style plus a strength. Everything else — which face,
/// which person, which tracked object — is expressed through the mask, which is
/// why the same render path serves all six scopes.
struct BlurRegion: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var scope: BlurScope
    var style: BlurStyle
    /// 0...1, mapped onto a radius or cell size by the render engine.
    var strength: Double
    /// `nil` for `.full`, where the whole frame is affected.
    var mask: MaskDefinition?
    /// When set, the blur only exists for part of the timeline.
    var timeRange: TimeRange?
    /// For `.person` and `.background`: blur everything *except* the subject.
    var invertsSubject: Bool
    var keyframes: KeyframeSet

    init(
        id: UUID = UUID(),
        scope: BlurScope,
        style: BlurStyle = .gaussian,
        strength: Double = 0.55,
        mask: MaskDefinition? = nil,
        timeRange: TimeRange? = nil,
        invertsSubject: Bool = false,
        keyframes: KeyframeSet = KeyframeSet()
    ) {
        self.id = id
        self.scope = scope
        self.style = style
        self.strength = min(max(strength, 0), 1)
        self.mask = mask
        self.timeRange = timeRange
        self.invertsSubject = invertsSubject
        self.keyframes = keyframes
    }

    /// A blur of the given scope with the mask that scope implies.
    static func make(scope: BlurScope) -> BlurRegion {
        switch scope {
        case .full:
            return BlurRegion(scope: .full, mask: nil)
        case .area:
            return BlurRegion(scope: .area, mask: MaskDefinition())
        case .face:
            return BlurRegion(
                scope: .face, style: .pixelate,
                mask: MaskDefinition(shape: .face(detectionID: UUID()), feather: 0.35)
            )
        case .person:
            return BlurRegion(
                scope: .person,
                mask: MaskDefinition(shape: .person(instance: 1), feather: 0.30)
            )
        case .background:
            return BlurRegion(
                scope: .background, strength: 0.65,
                mask: MaskDefinition(shape: .foregroundSubject, feather: 0.28),
                invertsSubject: true
            )
        case .track:
            return BlurRegion(
                scope: .track, style: .pixelate,
                mask: MaskDefinition(shape: .roundedRectangle(cornerRadius: 0.06), feather: 0.2)
            )
        }
    }

    func strength(at time: TimeInterval) -> Double {
        min(max(keyframes.value(.blurStrength, at: time, fallback: strength), 0), 1)
    }

    func isActive(at time: TimeInterval) -> Bool {
        guard let timeRange else { return true }
        return timeRange.contains(time)
    }

    var displayName: String {
        switch scope {
        case .full: String(localized: "Full Blur", comment: "Blur layer name")
        case .area: String(localized: "Area Blur", comment: "Blur layer name")
        case .face: String(localized: "Face Blur", comment: "Blur layer name")
        case .person: String(localized: "Person Blur", comment: "Blur layer name")
        case .background: String(localized: "Background Blur", comment: "Blur layer name")
        case .track: String(localized: "Tracked Blur", comment: "Blur layer name")
        }
    }
}
