import SwiftUI
import UIKit

/// The media, and everything drawn over it.
///
/// One view for both kinds of edit: a still shows the rendered preview, a video
/// shows the player, and the direct-manipulation layer — overlay handles, crop
/// rectangle, drawing canvas — composites on top of whichever it is.
struct EditorCanvasView: View {
    let session: EditorSession
    let playback: PlaybackEngine
    let preview: PreviewCoordinator
    @Binding var detail: EditorDetail?

    @State private var loadFailure: FramesError?
    @State private var cropDraft: CropState?

    /// Comfortably above the longest edge of any current iPhone display, so the
    /// preview is never soft, and far below what a modern camera produces, so
    /// memory stays flat.
    static let previewPixelBudget = 2436

    private var document: EditDocument { session.document }
    private var isCropping: Bool { detail == .crop }
    private var isDrawing: Bool { detail == .draw }

    var body: some View {
        GeometryReader { proxy in
            let media = mediaFrame(in: proxy.size)

            ZStack {
                Color(.secondarySystemBackground)
                    .ignoresSafeArea(edges: .horizontal)
                    .onTapGesture { session.clearSelection() }

                content
                    .frame(width: media.width, height: media.height)
                    .position(x: media.midX, y: media.midY)
                    .allowsHitTesting(false)

                if document.safeAreaGuides.isEnabled {
                    SafeAreaGuidesView(guides: document.safeAreaGuides)
                        .frame(width: media.width, height: media.height)
                        .position(x: media.midX, y: media.midY)
                        .allowsHitTesting(false)
                }

                if !session.isShowingOriginal {
                    CanvasLayerHandles(
                        session: session,
                        mediaFrame: media,
                        isEnabled: !isCropping
                    )
                }

                if isDrawing, case .drawing(let id) = session.selection,
                   let drawing = document.drawings.first(where: { $0.id == id }) {
                    DrawingCanvasView(
                        data: Binding(
                            get: { drawing.pencilData },
                            set: { _ in }
                        ),
                        isActive: true
                    ) { data in
                        session.updateDrawing(id, isFinal: false) { $0.pencilData = data }
                    }
                    .frame(width: media.width, height: media.height)
                    .position(x: media.midX, y: media.midY)
                }

                if isCropping {
                    CropOverlayView(
                        crop: Binding(
                            get: { cropDraft ?? document.currentCrop(forClip: session.activeClipID) },
                            set: { cropDraft = $0 }
                        ),
                        mediaFrame: media,
                        constrainedAspect: constrainedAspect,
                        onCommit: {
                            if let cropDraft {
                                session.updateCrop(cropDraft, isFinal: true)
                            }
                            cropDraft = nil
                        }
                    )
                }
            }
            .contentShape(Rectangle())
            // Press and hold anywhere on the media to see the original. This
            // is why there is no separate compare screen.
            .gesture(
                LongPressGesture(minimumDuration: 0.25)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        switch value {
                        case .second(true, _):
                            if !session.isShowingOriginal {
                                session.isShowingOriginal = true
                                preview.prepareOriginal()
                                Haptics.boundary()
                            }
                        default:
                            break
                        }
                    }
                    .onEnded { _ in
                        session.isShowingOriginal = false
                    },
                including: isCropping || isDrawing ? .subviews : .all
            )
        }
        .task(id: document.primaryAsset?.id) {
            preview.refresh()
        }
        .onChange(of: FrameComposer.visualSignature(of: document, at: session.currentTime)) { _, _ in
            preview.documentChanged()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            document.kind == .video
                ? Text("Video preview", comment: "Accessibility label")
                : Text("Photo preview", comment: "Accessibility label")
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch document.kind {
        case .video:
            ZStack {
                PlayerLayerView(player: playback.player)
                if session.isShowingOriginal {
                    // Showing the source with no composition attached is the
                    // truthful "before" for video: the same frames, ungraded.
                    OriginalBadge()
                }
            }
        case .photo:
            if session.isShowingOriginal, let original = preview.originalImage {
                Image(decorative: original, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(alignment: .top) { OriginalBadge() }
            } else if let image = preview.image {
                Image(decorative: image, scale: 1, orientation: .up)
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

    private var constrainedAspect: CGFloat? {
        let crop = cropDraft ?? document.currentCrop(forClip: session.activeClipID)
        guard let ratio = crop.aspect.ratio else { return nil }
        let sourceAspect = document.primaryAsset?.aspectRatio ?? 1
        return ratio / max(sourceAspect, 0.001)
    }

    /// The rect the media occupies, letterboxed inside the available space.
    private func mediaFrame(in size: CGSize) -> CGRect {
        let aspect = max(document.outputAspectRatio, 0.05)
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }
}

/// The marker shown while the user is holding to compare.
private struct OriginalBadge: View {
    var body: some View {
        Text("Original", comment: "Before/after badge")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

/// Optional guides for vertical layouts.
///
/// Deliberately generic — regions where captions and system controls usually
/// sit — rather than any particular app's chrome.
struct SafeAreaGuidesView: View {
    let guides: SafeAreaGuides

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(EdgeInsets(
                        top: size.height * guides.topInset,
                        leading: 0,
                        bottom: size.height * guides.bottomInset,
                        trailing: size.width * guides.trailingInset
                    ))
            }
        }
        .accessibilityHidden(true)
    }
}
