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
    @State private var preview = PreviewCoordinator()
    @State private var detail: EditorDetail?
    @State private var isConfirmingClose = false
    @State private var isShowingExport = false

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(
                session: session,
                onClose: requestClose,
                onExport: {
                    playback.pause()
                    isShowingExport = true
                }
            )

            EditorCanvasView(
                session: session,
                playback: playback,
                preview: preview,
                detail: $detail
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.document.kind == .video {
                TransportControls(session: session, playback: playback)
                    .padding(.top, 6)
                TimelineView(session: session, playback: playback)
                    .padding(.top, 2)
            }

            EditorBottomArea(session: session, playback: playback, detail: $detail)
                .padding(.bottom, 4)
        }
        .background(Color(.systemBackground))
        .task { await prepare() }
        .task(id: preview.compositionSignature) { await rebuildComposition() }
        .onDisappear {
            playback.tearDown()
        }
        .onChange(of: session.currentTime) { _, newValue in
            // Scrubbing on the timeline drives the player; playing drives the
            // timeline. Only follow the timeline when the user is the one
            // moving it.
            guard !playback.isPlaying, abs(playback.currentTime - newValue) > 0.02 else { return }
            playback.seek(to: newValue)
        }
        .onChange(of: playback.currentTime) { _, newValue in
            guard playback.isPlaying else { return }
            session.seek(to: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .framesRequestInspector)) { notification in
            guard let raw = notification.userInfo?[FramesInspectorRequest.key] as? String,
                  let route = EditorDetail(rawValue: raw)
            else { return }
            detail = route
        }
        .sheet(isPresented: $isShowingExport) {
            ExportView(session: session) {
                app.closeEditor()
            }
        }
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

    // MARK: - Lifecycle

    private func requestClose() {
        playback.pause()
        if session.document.isPristine {
            playback.tearDown()
            app.closeEditor()
        } else {
            isConfirmingClose = true
        }
    }

    private func prepare() async {
        Haptics.prepare()
        preview.attach(session: session)
        if session.document.kind == .video {
            await rebuildComposition()
        }
    }

    /// Rebuilds the player's composition, but only when the *structure* of the
    /// edit changed. Colour, blur and overlays are the compositor's job and
    /// never require a new player item.
    private func rebuildComposition() async {
        guard session.document.kind == .video else { return }
        do {
            let build = try await preview.compositionEngine.build(
                document: session.document,
                quality: .preview
            )
            playback.load(
                asset: build.composition,
                videoComposition: build.videoComposition,
                audioMix: build.audioMix,
                signature: build.structureSignature
            )
            playback.updateVideoComposition(build.videoComposition)
            playback.updateAudioMix(build.audioMix)
        } catch let error as FramesError {
            app.present(error)
        } catch {
            app.present(.renderFailed(error.localizedDescription))
        }
    }
}

/// `X   Undo  Redo   Export`, and nothing else.
private struct EditorTopBar: View {
    let session: EditorSession
    let onClose: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close", comment: "Editor action"))

            Spacer()

            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!session.canUndo)
            .accessibilityLabel(Text("Undo", comment: "Editor action"))

            Button {
                session.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.body.weight(.medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!session.canRedo)
            .accessibilityLabel(Text("Redo", comment: "Editor action"))

            Spacer()

            Button(action: onExport) {
                Text("Export", comment: "Editor action")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.glassProminent)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
