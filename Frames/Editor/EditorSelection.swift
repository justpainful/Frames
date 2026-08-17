import Foundation

/// What the user currently has selected.
///
/// The bottom toolbar is a pure function of this value. That is the whole
/// contextual-tools mechanism: tap an object, the selection changes, the
/// controls for that object appear. There is no separate "mode" to get stuck
/// in, and no panel to navigate back out of.
enum EditorSelection: Hashable, Sendable {
    case none
    case clip(UUID)
    case text(UUID)
    case imageOverlay(UUID)
    case drawing(UUID)
    case blur(UUID)
    case audio(UUID)
    case selectiveAdjustment(UUID)
    case effect(UUID)

    var isNone: Bool { self == .none }

    var identifier: UUID? {
        switch self {
        case .none: nil
        case .clip(let id), .text(let id), .imageOverlay(let id), .drawing(let id),
             .blur(let id), .audio(let id), .selectiveAdjustment(let id), .effect(let id):
            id
        }
    }

    /// True when the selected object is drawn on the canvas and can be dragged
    /// directly.
    var isCanvasLayer: Bool {
        switch self {
        case .text, .imageOverlay, .drawing, .blur, .selectiveAdjustment: true
        case .none, .clip, .audio, .effect: false
        }
    }

    var accessibilityName: String {
        switch self {
        case .none: String(localized: "Nothing selected", comment: "Selection")
        case .clip: String(localized: "Video clip selected", comment: "Selection")
        case .text: String(localized: "Text selected", comment: "Selection")
        case .imageOverlay: String(localized: "Image selected", comment: "Selection")
        case .drawing: String(localized: "Drawing selected", comment: "Selection")
        case .blur: String(localized: "Blur selected", comment: "Selection")
        case .audio: String(localized: "Audio selected", comment: "Selection")
        case .selectiveAdjustment: String(localized: "Selective adjustment selected", comment: "Selection")
        case .effect: String(localized: "Effect selected", comment: "Selection")
        }
    }
}
