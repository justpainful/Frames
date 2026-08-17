import SwiftUI

/// The diamond.
///
/// Keyframes are an advanced feature in Frames and this is the only place they
/// appear: a small control next to a property that is already being edited
/// directly. Nobody has to understand keyframes to use the app, and nobody who
/// wants one has to go looking for a separate mode.
struct KeyframeControl: View {
    let session: EditorSession
    let property: KeyframeProperty

    private var keyframes: KeyframeSet? {
        switch session.selection {
        case .text(let id):
            session.document.textOverlays.first { $0.id == id }?.keyframes
        case .imageOverlay(let id):
            session.document.imageOverlays.first { $0.id == id }?.keyframes
        case .blur(let id):
            session.document.blurRegions.first { $0.id == id }?.keyframes
        case .audio(let id):
            session.document.audioClips.first { $0.id == id }?.keyframes
        case .clip(let id):
            session.document.videoTrack.first { $0.id == id }?.keyframes
        default:
            nil
        }
    }

    /// Keyframes on a clip are relative to the clip's own start.
    private var localTime: TimeInterval {
        if case .clip(let id) = session.selection,
           let start = session.document.startTime(ofClip: id) {
            return session.currentTime - start
        }
        return session.currentTime
    }

    private var hasKeyframeHere: Bool {
        keyframes?.hasKeyframe(property, at: localTime) ?? false
    }

    private var isAnimated: Bool {
        keyframes?.isAnimated(property) ?? false
    }

    var body: some View {
        Button {
            session.toggleKeyframe(property)
        } label: {
            Image(systemName: hasKeyframeHere ? "diamond.fill" : "diamond")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasKeyframeHere || isAnimated ? Color.accentColor : Color.secondary)
        .accessibilityLabel(
            hasKeyframeHere
                ? Text("Remove keyframe", comment: "Keyframe action")
                : Text("Add keyframe", comment: "Keyframe action")
        )
        .accessibilityValue(property.displayName)
    }
}

/// A parameter slider with a keyframe diamond beside it.
///
/// Used wherever a property can be animated, so the direct-manipulation
/// control and the advanced control sit together rather than in different
/// places.
struct KeyframableParameterSlider: View {
    let session: EditorSession
    let property: KeyframeProperty
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double?
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// Only video edits have a timeline to animate along.
    private var supportsKeyframes: Bool {
        session.document.kind == .video
    }

    var body: some View {
        HStack(spacing: 8) {
            ParameterSlider(
                title: title,
                value: $value,
                range: range,
                neutral: neutral,
                format: format,
                onEditingChanged: onEditingChanged
            )

            if supportsKeyframes {
                KeyframeControl(session: session, property: property)
                    .padding(.top, 16)
            }
        }
    }
}
