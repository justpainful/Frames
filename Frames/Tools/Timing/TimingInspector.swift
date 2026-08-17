import SwiftUI

/// When a layer is on screen.
///
/// Overlays on video have a time range, and this is where it is set. Photos
/// have no timeline, so this shows nothing to change and says so rather than
/// presenting disabled controls.
struct TimingInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    private var duration: TimeInterval { max(session.document.duration, 0.1) }

    var body: some View {
        InspectorSurface(title: String(localized: "Timing", comment: "Tool title"), onDone: onDone) {
            if session.document.kind == .photo {
                Text("A photo has no timeline, so this layer is always visible.",
                     comment: "Timing empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let range = currentRange {
                VStack(spacing: 12) {
                    ParameterSlider(
                        title: String(localized: "Start", comment: "Timing control"),
                        value: Binding(
                            get: { range.start },
                            set: { value in
                                let clamped = min(max(value, 0), range.end - 0.1)
                                setRange(TimeRange(start: clamped, end: range.end), isFinal: false)
                            }
                        ),
                        range: 0...duration,
                        neutral: nil,
                        format: { $0.framesTimecode }
                    ) { editing in
                        if !editing { session.endInteraction() }
                    }

                    ParameterSlider(
                        title: String(localized: "End", comment: "Timing control"),
                        value: Binding(
                            get: { range.end },
                            set: { value in
                                let clamped = min(max(value, range.start + 0.1), duration)
                                setRange(TimeRange(start: range.start, end: clamped), isFinal: false)
                            }
                        ),
                        range: 0...duration,
                        neutral: nil,
                        format: { $0.framesTimecode }
                    ) { editing in
                        if !editing { session.endInteraction() }
                    }

                    HStack(spacing: 10) {
                        Button {
                            setRange(TimeRange(start: session.currentTime, end: range.end), isFinal: true)
                            Haptics.snap()
                        } label: {
                            Text("Start Here", comment: "Timing action")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)

                        Button {
                            setRange(TimeRange(start: range.start, end: session.currentTime), isFinal: true)
                            Haptics.snap()
                        } label: {
                            Text("End Here", comment: "Timing action")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)

                        Button {
                            setRange(TimeRange(start: 0, duration: duration), isFinal: true)
                            Haptics.snap()
                        } label: {
                            Text("Whole Video", comment: "Timing action")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }

                    Divider()

                    TransformKeyframeRow(session: session)
                }
            } else {
                Text("Select something on the timeline to change when it appears.",
                     comment: "Timing empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var currentRange: TimeRange? {
        let whole = TimeRange(start: 0, duration: duration)
        switch session.selection {
        case .text(let id):
            return session.document.textOverlays.first { $0.id == id }?.timeRange ?? whole
        case .imageOverlay(let id):
            return session.document.imageOverlays.first { $0.id == id }?.timeRange ?? whole
        case .drawing(let id):
            return session.document.drawings.first { $0.id == id }?.timeRange ?? whole
        case .blur(let id):
            return session.document.blurRegions.first { $0.id == id }?.timeRange ?? whole
        case .selectiveAdjustment(let id):
            return session.document.selectiveAdjustments.first { $0.id == id }?.timeRange ?? whole
        default:
            return nil
        }
    }

    private func setRange(_ range: TimeRange, isFinal: Bool) {
        switch session.selection {
        case .text(let id):
            session.updateText(id, isFinal: isFinal) { $0.timeRange = range }
        case .imageOverlay(let id):
            session.updateImageOverlay(id, isFinal: isFinal) { $0.timeRange = range }
        case .drawing(let id):
            session.updateDrawing(id, isFinal: isFinal) { $0.timeRange = range }
        case .blur(let id):
            session.updateBlur(id, isFinal: isFinal) { $0.timeRange = range }
        case .selectiveAdjustment(let id):
            session.updateSelectiveAdjustment(id, isFinal: isFinal) { $0.timeRange = range }
        default:
            break
        }
    }
}
