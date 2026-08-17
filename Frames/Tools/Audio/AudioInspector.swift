import SwiftUI

/// Audio controls: the selected clip's level, trim and fades, plus the entry
/// points for adding audio when nothing is selected.
struct AudioInspector: View {
    let session: EditorSession
    let focus: EditorDetail
    let onDone: () -> Void

    @Environment(AppModel.self) private var app
    @State private var recorder = VoiceoverRecorder()
    @State private var isExtracting = false

    private var clip: AudioClip? {
        guard case .audio(let id) = session.selection else { return nil }
        return session.document.audioClips.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(title: title, onDone: onDone) {
            if let clip {
                clipControls(clip)
            } else {
                sourceControls
            }
        }
    }

    private var title: String {
        clip?.role.displayName ?? String(localized: "Audio", comment: "Tool title")
    }

    // MARK: - Adding

    private var sourceControls: some View {
        VStack(spacing: 12) {
            if recorder.isRecording {
                recordingControls
            } else {
                HStack(spacing: 10) {
                    Button {
                        Task { await startRecording() }
                    } label: {
                        Label {
                            Text("Record Voice", comment: "Audio action")
                        } icon: {
                            Image(systemName: "mic.fill")
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        Task { await extractFromSource() }
                    } label: {
                        Label {
                            Text("Extract Audio", comment: "Audio action")
                        } icon: {
                            Image(systemName: "waveform.badge.plus")
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .disabled(isExtracting || !(session.document.primaryAsset?.hasAudioTrack ?? false))
                }

                Toggle(isOn: Binding(
                    get: { session.document.audioMix.autoDuck },
                    set: { session.setAutoDuck($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto Duck", comment: "Audio option")
                            .font(.subheadline)
                        Text("Lowers music while a voiceover is playing.",
                             comment: "Audio option detail")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(recorder.isRecording ? 1 : 0.3)
                Text(recorder.elapsed.framesTimecode)
                    .font(.subheadline.monospacedDigit())
                Spacer()
                LevelMeter(level: recorder.level)
                    .frame(width: 90, height: 12)
            }

            Button {
                Task { await stopRecording() }
            } label: {
                Label {
                    Text("Stop", comment: "Audio action")
                } icon: {
                    Image(systemName: "stop.fill")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
        }
    }

    // MARK: - Editing

    @ViewBuilder
    private func clipControls(_ clip: AudioClip) -> some View {
        switch focus {
        case .audioTrim:
            trimControls(clip)
        case .fade:
            fadeControls(clip)
        default:
            levelControls(clip)
        }
    }

    private func levelControls(_ clip: AudioClip) -> some View {
        VStack(spacing: 10) {
            ParameterSlider(
                title: String(localized: "Level", comment: "Audio control"),
                value: Binding(
                    get: { clip.volume },
                    set: { value in
                        session.updateAudioClip(clip.id, isFinal: false) { $0.volume = value }
                    }
                ),
                range: 0...2,
                neutral: 1,
                format: { "\(Int(($0 * 100).rounded()))%" }
            ) { editing in
                if !editing { session.endInteraction() }
            }
            .disabled(clip.isMuted)
            .opacity(clip.isMuted ? 0.4 : 1)

            ParameterSlider(
                title: String(localized: "Speed", comment: "Audio control"),
                value: Binding(
                    get: { clip.speed },
                    set: { value in
                        session.updateAudioClip(clip.id, isFinal: false) { $0.speed = value }
                    }
                ),
                range: 0.25...4,
                neutral: 1,
                format: { String(format: "%.2gx", $0) }
            ) { editing in
                if !editing { session.endInteraction() }
            }
        }
    }

    private func trimControls(_ clip: AudioClip) -> some View {
        let assetDuration = session.document.asset(id: clip.assetID)?.duration ?? clip.source.duration
        return VStack(spacing: 10) {
            ParameterSlider(
                title: String(localized: "Start In Source", comment: "Audio control"),
                value: Binding(
                    get: { clip.source.start },
                    set: { value in
                        let clamped = min(max(value, 0), max(assetDuration - 0.2, 0))
                        session.updateAudioClip(clip.id, isFinal: false) { updated in
                            let end = updated.source.end
                            updated.source = TimeRange(start: clamped, end: max(end, clamped + 0.2))
                        }
                    }
                ),
                range: 0...max(assetDuration, 0.2),
                neutral: nil,
                format: { $0.framesTimecode }
            ) { editing in
                if !editing { session.endInteraction() }
            }

            ParameterSlider(
                title: String(localized: "Length", comment: "Audio control"),
                value: Binding(
                    get: { clip.source.duration },
                    set: { value in
                        session.updateAudioClip(clip.id, isFinal: false) { updated in
                            let available = max(assetDuration - updated.source.start, 0.2)
                            updated.source.duration = min(max(value, 0.2), available)
                        }
                    }
                ),
                range: 0.2...max(assetDuration, 0.2),
                neutral: nil,
                format: { $0.framesTimecode }
            ) { editing in
                if !editing { session.endInteraction() }
            }

            ParameterSlider(
                title: String(localized: "Position", comment: "Audio control"),
                value: Binding(
                    get: { clip.timelineStart },
                    set: { value in
                        session.updateAudioClip(clip.id, isFinal: false) {
                            $0.timelineStart = max(value, 0)
                        }
                    }
                ),
                range: 0...max(session.document.videoDuration, 0.2),
                neutral: nil,
                format: { $0.framesTimecode }
            ) { editing in
                if !editing { session.endInteraction() }
            }
        }
    }

    private func fadeControls(_ clip: AudioClip) -> some View {
        VStack(spacing: 10) {
            ParameterSlider(
                title: String(localized: "Fade In", comment: "Audio control"),
                value: Binding(
                    get: { clip.fadeIn },
                    set: { value in
                        session.updateAudioClip(clip.id, isFinal: false) {
                            $0.fadeIn = min(max(value, 0), $0.timelineDuration / 2)
                        }
                    }
                ),
                range: 0...max(clip.timelineDuration / 2, 0.2),
                neutral: 0,
                format: { String(format: "%.1fs", $0) }
            ) { editing in
                if !editing { session.endInteraction() }
            }

            ParameterSlider(
                title: String(localized: "Fade Out", comment: "Audio control"),
                value: Binding(
                    get: { clip.fadeOut },
                    set: { value in
                        session.updateAudioClip(clip.id, isFinal: false) {
                            $0.fadeOut = min(max(value, 0), $0.timelineDuration / 2)
                        }
                    }
                ),
                range: 0...max(clip.timelineDuration / 2, 0.2),
                neutral: 0,
                format: { String(format: "%.1fs", $0) }
            ) { editing in
                if !editing { session.endInteraction() }
            }
        }
    }

    // MARK: - Actions

    private func startRecording() async {
        do {
            try await recorder.start(at: session.currentTime)
        } catch let error as FramesError {
            app.present(error)
        } catch {
            app.present(.microphonePermissionDenied)
        }
    }

    private func stopRecording() async {
        do {
            guard let result = try await recorder.stop() else { return }
            _ = session.addAudioClip(
                asset: result.asset,
                role: .voiceover,
                at: result.startTime,
                label: String(localized: "Voiceover", comment: "Audio clip label")
            )
            Haptics.success()
        } catch let error as FramesError {
            app.present(error)
        } catch {
            app.present(.exportFailed(error.localizedDescription))
        }
    }

    private func extractFromSource() async {
        guard let asset = session.document.primaryAsset else { return }
        isExtracting = true
        defer { isExtracting = false }
        do {
            let extracted = try await AudioImportService().extractAudio(from: asset)
            _ = session.addAudioClip(
                asset: extracted,
                role: .extracted,
                at: 0,
                label: String(localized: "Extracted Audio", comment: "Audio clip label")
            )
        } catch let error as FramesError {
            app.present(error)
        } catch {
            app.present(.importFailed(error.localizedDescription))
        }
    }
}

/// A small live input meter, shown while recording.
struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(level > 0.92 ? Color.red : Color.accentColor)
                    .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .accessibilityLabel(Text("Input level", comment: "Accessibility label"))
        .accessibilityValue("\(Int(level * 100))%")
    }
}
