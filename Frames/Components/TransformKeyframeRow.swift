import SwiftUI

/// Diamonds for the properties a layer is moved by directly.
///
/// Position, scale, rotation and opacity are set by dragging on the canvas, not
/// by sliders, so their keyframe controls cannot hang off a slider the way blur
/// strength and volume do. This row is where they live: one diamond per
/// property, showing at a glance which are animated and whether there is a
/// keyframe at the playhead.
struct TransformKeyframeRow: View {
    let session: EditorSession

    private static let properties: [KeyframeProperty] = [
        .positionX, .positionY, .scale, .rotation, .opacity
    ]

    private var isApplicable: Bool {
        session.document.kind == .video && session.selection.isCanvasLayer
    }

    var body: some View {
        if isApplicable {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Keyframes", comment: "Keyframe section")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(session.currentTime.framesTimecode)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                HStack(spacing: 2) {
                    ForEach(Self.properties) { property in
                        VStack(spacing: 2) {
                            KeyframeControl(session: session, property: property)
                            Text(shortName(for: property))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// Full names do not fit five across on a phone, and the diamond plus a
    /// two-character label is unambiguous once the section is titled.
    private func shortName(for property: KeyframeProperty) -> String {
        switch property {
        case .positionX: "X"
        case .positionY: "Y"
        case .scale: String(localized: "Size", comment: "Keyframe short name")
        case .rotation: String(localized: "Turn", comment: "Keyframe short name")
        case .opacity: String(localized: "Fade", comment: "Keyframe short name")
        default: property.displayName
        }
    }
}
