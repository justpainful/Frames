import SwiftUI

/// Trim handles for the selected clip.
///
/// Both edges are dragged in timeline seconds and the preview follows the
/// finger, so the frame under the handle is the frame that will become the new
/// in- or out-point.
struct TrimInspector: View {
    let session: EditorSession
    let playback: PlaybackEngine
    let onDone: () -> Void

    @State private var draftStart: TimeInterval?
    @State private var draftDuration: TimeInterval?

    private var clip: VideoClip? {
        guard let id = session.activeClipID else { return nil }
        return session.document.videoTrack.first { $0.id == id }
    }

    private var assetDuration: TimeInterval {
        guard let clip, let asset = session.document.asset(id: clip.assetID) else { return 0 }
        return asset.duration
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Trim", comment: "Tool title"), onDone: onDone) {
            if let clip {
                VStack(spacing: 14) {
                    HStack {
                        Label {
                            Text(currentStart.framesTimecode)
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "arrow.right.to.line")
                        }
                        Spacer()
                        Text(currentDuration.framesTimecode)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Spacer()
                        Label {
                            Text((currentStart + currentDuration).framesTimecode)
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "arrow.left.to.line")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ParameterSlider(
                        title: String(localized: "Start", comment: "Trim control"),
                        value: Binding(
                            get: { currentStart },
                            set: { newValue in
                                let maximum = currentStart + currentDuration - VideoClip.minimumDuration
                                let clamped = min(max(newValue, 0), max(maximum, 0))
                                let end = currentStart + currentDuration
                                draftStart = clamped
                                draftDuration = end - clamped
                                commit(isFinal: false)
                                playback.seek(to: clipTimelineStart)
                            }
                        ),
                        range: 0...max(assetDuration, 0.1),
                        neutral: nil,
                        format: { $0.framesTimecode }
                    ) { editing in
                        if !editing { commit(isFinal: true) }
                    }

                    ParameterSlider(
                        title: String(localized: "End", comment: "Trim control"),
                        value: Binding(
                            get: { currentStart + currentDuration },
                            set: { newValue in
                                let minimum = currentStart + VideoClip.minimumDuration
                                let clamped = min(max(newValue, minimum), assetDuration)
                                draftStart = currentStart
                                draftDuration = clamped - currentStart
                                commit(isFinal: false)
                            }
                        ),
                        range: 0...max(assetDuration, 0.1),
                        neutral: nil,
                        format: { $0.framesTimecode }
                    ) { editing in
                        if !editing { commit(isFinal: true) }
                    }
                }
            } else {
                Text("Select a clip to trim it.", comment: "Trim empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var currentStart: TimeInterval {
        draftStart ?? clip?.source.start ?? 0
    }

    private var currentDuration: TimeInterval {
        draftDuration ?? clip?.source.duration ?? 0
    }

    private var clipTimelineStart: TimeInterval {
        guard let clip else { return 0 }
        return session.document.startTime(ofClip: clip.id) ?? 0
    }

    private func commit(isFinal: Bool) {
        guard let clip else { return }
        session.setClipSource(
            clip.id,
            start: currentStart,
            duration: currentDuration,
            isFinal: isFinal
        )
        if isFinal {
            draftStart = nil
            draftDuration = nil
            Haptics.snap()
        }
    }
}

/// Confirmation for Remove Range.
///
/// The band itself is dragged on the timeline; this is the readout and the two
/// buttons, so the operation is drag, look, confirm.
struct RemoveRangeInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    var body: some View {
        InspectorSurface(title: String(localized: "Remove Range", comment: "Tool title")) {
            VStack(spacing: 12) {
                if let range = session.pendingRemovalRange {
                    HStack {
                        Text(range.start.framesTimecode)
                            .monospacedDigit()
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                        Text(range.end.framesTimecode)
                            .monospacedDigit()
                        Spacer()
                        Text(
                            String(
                                localized: "Removing \(range.duration.framesTimecode)",
                                comment: "Remove range readout"
                            )
                        )
                        .foregroundStyle(.red)
                    }
                    .font(.subheadline)

                    Text("Everything after the range moves back to close the gap.",
                         comment: "Remove range explanation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button {
                        session.cancelRangeSelection()
                        onDone()
                    } label: {
                        Text("Cancel", comment: "Remove range action")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    Button {
                        if session.commitRangeRemoval() { onDone() }
                    } label: {
                        Text("Delete", comment: "Remove range action")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                }
            }
        }
        .onAppear {
            if session.pendingRemovalRange == nil {
                session.beginRangeSelection()
            }
        }
    }
}

/// Playback rate, reverse and freeze frame.
struct SpeedInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    private static let presets: [Double] = [0.25, 0.5, 1, 2, 4]

    private var clip: VideoClip? {
        guard let id = session.activeClipID else { return nil }
        return session.document.videoTrack.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Speed", comment: "Tool title"), onDone: onDone) {
            if let clip {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        ForEach(Self.presets, id: \.self) { value in
                            Button {
                                session.setSpeed(value, forClip: clip.id, isFinal: true)
                                Haptics.snap()
                            } label: {
                                Text(label(for: value))
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .background {
                                Capsule().fill(
                                    abs(clip.speed - value) < 0.01
                                        ? Color.accentColor
                                        : Color(.tertiarySystemFill)
                                )
                            }
                            .foregroundStyle(abs(clip.speed - value) < 0.01 ? Color.white : Color.primary)
                        }
                    }

                    ParameterSlider(
                        title: String(localized: "Rate", comment: "Speed control"),
                        value: Binding(
                            get: { clip.speed },
                            set: { session.setSpeed($0, forClip: clip.id, isFinal: false) }
                        ),
                        range: VideoClip.minimumSpeed...VideoClip.maximumSpeed,
                        neutral: 1,
                        format: { String(format: "%.2gx", $0) }
                    ) { editing in
                        if !editing {
                            session.setSpeed(clip.speed, forClip: clip.id, isFinal: true)
                        }
                    }

                    HStack {
                        Text(
                            String(
                                localized: "New length \(clip.timelineDuration.framesTimecode)",
                                comment: "Speed readout"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            session.insertFreezeFrame()
                        } label: {
                            Label {
                                Text("Freeze Frame", comment: "Speed action")
                            } icon: {
                                Image(systemName: "snowflake")
                            }
                            .font(.subheadline)
                        }
                        .buttonStyle(.glass)
                    }
                }
            } else {
                Text("Select a clip to change its speed.", comment: "Speed empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func label(for value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%.2g×", value)
    }
}

/// Clip or audio-clip level.
struct VolumeInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    var body: some View {
        InspectorSurface(title: String(localized: "Volume", comment: "Tool title"), onDone: onDone) {
            if case .audio(let audioID) = session.selection,
               let clip = session.document.audioClips.first(where: { $0.id == audioID }) {
                volumeControls(
                    value: clip.volume,
                    isMuted: clip.isMuted,
                    set: { value, isFinal in
                        session.updateAudioClip(audioID, isFinal: isFinal) { $0.volume = value }
                    },
                    toggleMute: {
                        session.updateAudioClip(audioID) { $0.isMuted.toggle() }
                        Haptics.snap()
                    }
                )
            } else if let clipID = session.activeClipID,
                      let clip = session.document.videoTrack.first(where: { $0.id == clipID }) {
                volumeControls(
                    value: clip.volume,
                    isMuted: clip.isMuted,
                    set: { value, isFinal in
                        session.setClipVolume(value, forClip: clipID, isFinal: isFinal)
                    },
                    toggleMute: { session.toggleClipMute(clipID) }
                )
            } else {
                Text("Select a clip to change its level.", comment: "Volume empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func volumeControls(
        value: Double,
        isMuted: Bool,
        set: @escaping (Double, Bool) -> Void,
        toggleMute: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            ParameterSlider(
                title: String(localized: "Level", comment: "Volume control"),
                value: Binding(get: { value }, set: { set($0, false) }),
                range: 0...2,
                neutral: 1,
                format: { "\(Int(($0 * 100).rounded()))%" }
            ) { editing in
                if !editing { set(value, true) }
            }
            .disabled(isMuted)
            .opacity(isMuted ? 0.4 : 1)

            Button(action: toggleMute) {
                Label {
                    Text(isMuted
                         ? String(localized: "Unmute", comment: "Volume action")
                         : String(localized: "Mute", comment: "Volume action"))
                } icon: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
        }
    }
}

/// The transition into the selected clip.
struct TransitionInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    private var clip: VideoClip? {
        guard case .clip(let id) = session.selection else { return nil }
        return session.document.videoTrack.first { $0.id == id }
    }

    private var isFirstClip: Bool {
        guard let clip else { return true }
        return session.document.videoTrack.first?.id == clip.id
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Transition", comment: "Tool title"), onDone: onDone) {
            if let clip, !isFirstClip {
                VStack(spacing: 14) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(TransitionKind.allCases) { kind in
                                Button {
                                    session.setTransition(
                                        Transition(kind: kind, duration: clip.transitionIn.duration),
                                        forClip: clip.id
                                    )
                                } label: {
                                    VStack(spacing: 5) {
                                        Image(systemName: kind.symbolName)
                                            .font(.system(size: 18))
                                            .frame(width: 44, height: 44)
                                            .background(
                                                Circle().fill(
                                                    clip.transitionIn.kind == kind
                                                        ? Color.accentColor
                                                        : Color(.tertiarySystemFill)
                                                )
                                            )
                                            .foregroundStyle(
                                                clip.transitionIn.kind == kind ? Color.white : Color.primary
                                            )
                                        Text(kind.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(kind.displayName)
                                .accessibilityAddTraits(
                                    clip.transitionIn.kind == kind ? [.isSelected, .isButton] : .isButton
                                )
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)

                    if clip.transitionIn.kind != .none {
                        ParameterSlider(
                            title: String(localized: "Duration", comment: "Transition control"),
                            value: Binding(
                                get: { clip.transitionIn.duration },
                                set: {
                                    session.setTransition(
                                        Transition(kind: clip.transitionIn.kind, duration: $0),
                                        forClip: clip.id
                                    )
                                }
                            ),
                            range: 0.1...2,
                            neutral: nil,
                            format: { String(format: "%.1fs", $0) }
                        )
                    }
                }
            } else {
                Text("A transition needs a clip before it.", comment: "Transition empty state")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
