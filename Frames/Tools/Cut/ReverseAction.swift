import SwiftUI

/// The Reverse control.
///
/// Reverse is the one editing operation in Frames that cannot be expressed as
/// numbers on a clip: `AVComposition` has no way to play a track backwards, so
/// the frames genuinely have to be re-written. That makes it the only tool with
/// a progress bar, and the only one that adds a file to the session.
///
/// It is presented honestly: it takes time, it says so, and it can be stopped.
struct ReverseButton: View {
    let session: EditorSession
    let clipID: UUID

    @Environment(AppModel.self) private var app
    @State private var progress: Double?
    @State private var task: Task<Void, Never>?

    private var clip: VideoClip? {
        session.document.videoTrack.first { $0.id == clipID }
    }

    var body: some View {
        Group {
            if let progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                    Button {
                        task?.cancel()
                        self.progress = nil
                    } label: {
                        Text("Stop", comment: "Reverse action")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            } else {
                Button {
                    start()
                } label: {
                    Label {
                        Text("Reverse", comment: "Speed action")
                    } icon: {
                        Image(systemName: "arrow.uturn.left.circle")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .disabled(clip == nil || clip?.isFrozen == true)
            }
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard let clip, let asset = session.document.asset(id: clip.assetID) else { return }
        let range = clip.source
        progress = 0

        task = Task {
            defer { progress = nil }
            do {
                let reversed = try await ReverseRenderer().reverse(
                    asset: asset,
                    range: range
                ) { value in
                    Task { @MainActor in self.progress = value }
                }

                // The clip now points at a new asset whose whole length *is*
                // the reversed range, so its source range starts at zero and
                // `isReversed` goes back to false: everything downstream treats
                // it as an ordinary clip.
                session.perform(String(localized: "Reverse", comment: "Undo action")) { document in
                    document.addAsset(reversed)
                    guard let index = document.videoTrack.firstIndex(where: { $0.id == clipID }) else { return }
                    document.videoTrack[index].assetID = reversed.id
                    document.videoTrack[index].source = TimeRange(start: 0, duration: reversed.duration)
                    document.videoTrack[index].isReversed = false
                }
                Haptics.success()
            } catch let error as FramesError {
                if error != .cancelled {
                    app.present(error)
                    Haptics.failure()
                }
            } catch {
                app.present(.renderFailed(error.localizedDescription))
                Haptics.failure()
            }
        }
    }
}
