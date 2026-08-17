import SwiftUI
import UIKit

/// The media itself.
///
/// One view for both kinds of edit: a still shows a decoded image, a video
/// shows the player. Everything drawn on top of the media — overlays, masks,
/// handles — composites over this.
struct EditorCanvasView: View {
    let session: EditorSession
    let playback: PlaybackEngine

    @State private var stillImage: CGImage?
    @State private var loadFailure: FramesError?

    /// Comfortably above the longest edge of any current iPhone display, so the
    /// preview is never soft, and far below what a modern camera produces, so
    /// memory stays flat.
    static let previewPixelBudget = 2436

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.secondarySystemBackground)
                    .ignoresSafeArea(edges: .horizontal)

                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .task(id: session.document.primaryAsset?.id) {
            await loadStillIfNeeded()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            session.document.kind == .video
                ? Text("Video preview", comment: "Accessibility label")
                : Text("Photo preview", comment: "Accessibility label")
        )
    }

    @ViewBuilder
    private var content: some View {
        switch session.document.kind {
        case .video:
            PlayerLayerView(player: playback.player)
                .allowsHitTesting(false)
        case .photo:
            if let stillImage {
                Image(decorative: stillImage, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loadFailure != nil {
                ContentUnavailableView {
                    Label {
                        Text("Can’t Show This Photo", comment: "Canvas failure title")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                } description: {
                    Text("The file couldn’t be read.", comment: "Canvas failure detail")
                }
            } else {
                ProgressView()
            }
        }
    }

    private func loadStillIfNeeded() async {
        guard session.document.kind == .photo,
              let asset = session.document.primaryAsset
        else { return }

        let url = SessionPaths.mediaURL(for: asset.fileName)
        do {
            // A preview never needs more than a screen's worth of pixels; the
            // export path is the only thing that touches full resolution.
            let image = try await ImageLoader.shared.image(
                at: url,
                maxPixelSize: EditorCanvasView.previewPixelBudget
            )
            stillImage = image
            loadFailure = nil
        } catch let error as FramesError {
            loadFailure = error
        } catch {
            loadFailure = .corruptMedia(error.localizedDescription)
        }
    }
}
