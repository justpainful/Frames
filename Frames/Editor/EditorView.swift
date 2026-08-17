import SwiftUI

/// The editor.
///
/// Three regions, always: a minimal top bar, the media, and whatever controls
/// the current selection calls for. The media is the largest thing on screen at
/// all times, which is the whole design.
struct EditorView: View {
    @Environment(AppModel.self) private var app
    let session: EditorSession

    @State private var playback = PlaybackEngine()
    @State private var isConfirmingClose = false

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(
                session: session,
                onClose: { requestClose() }
            )

            EditorCanvasView(session: session, playback: playback)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.document.kind == .video {
                TransportBar(session: session, playback: playback)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(.systemBackground))
        .task { await loadMedia() }
        .onDisappear { playback.tearDown() }
        .confirmationDialog(
            Text("Discard this edit?", comment: "Close confirmation"),
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task {
                    playback.tearDown()
                    await app.discardAndCloseEditor()
                }
            } label: {
                Text("Discard", comment: "Close confirmation action")
            }
            Button(role: .cancel) { } label: {
                Text("Keep Editing", comment: "Close confirmation action")
            }
        } message: {
            Text("Your changes haven’t been exported yet.", comment: "Close confirmation detail")
        }
    }

    private func requestClose() {
        if session.document.isPristine {
            playback.tearDown()
            app.closeEditor()
        } else {
            isConfirmingClose = true
        }
    }

    private func loadMedia() async {
        guard session.document.kind == .video,
              let asset = session.document.primaryAsset
        else { return }
        playback.load(url: SessionPaths.mediaURL(for: asset.fileName))
    }
}

/// `X   Undo  Redo   Export` and nothing else.
private struct EditorTopBar: View {
    let session: EditorSession
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
            }
            .accessibilityLabel(Text("Close", comment: "Editor action"))

            Spacer()

            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.medium))
            }
            .disabled(!session.canUndo)
            .accessibilityLabel(Text("Undo", comment: "Editor action"))

            Button {
                session.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.body.weight(.medium))
            }
            .disabled(!session.canRedo)
            .accessibilityLabel(Text("Redo", comment: "Editor action"))

            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// Play/pause plus a scrubber, for video.
private struct TransportBar: View {
    let session: EditorSession
    let playback: PlaybackEngine

    var body: some View {
        HStack(spacing: 14) {
            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .accessibilityLabel(
                playback.isPlaying
                    ? Text("Pause", comment: "Playback action")
                    : Text("Play", comment: "Playback action")
            )

            Text(playback.currentTime.framesTimecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .leading)
                .accessibilityLabel(Text("Current time", comment: "Accessibility label"))
                .accessibilityValue(playback.currentTime.framesTimecode)

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.1)
            ) {
                Text("Playhead", comment: "Accessibility label")
            } onEditingChanged: { editing in
                if editing {
                    playback.beginScrubbing()
                } else {
                    playback.endScrubbing()
                    playback.seek(to: playback.currentTime, precise: true)
                }
                session.seek(to: playback.currentTime)
            }

            Text(playback.duration.framesTimecode)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}
