import CoreGraphics
import CoreImage
import Foundation
import Observation
import OSLog

/// Keeps the on-screen preview in step with the document.
///
/// Two very different jobs sit behind one object because they answer the same
/// question — "what should the canvas show right now":
///
/// - For a photo, it renders through `ImageRenderEngine` and publishes a
///   `CGImage`, debounced so dragging a slider does not queue a render per
///   frame.
/// - For a video, it decides when the *composition* has to be rebuilt. Colour,
///   blur, effects and overlays are the compositor's job and need no rebuild;
///   only trims, splits, speed and audio changes do.
@MainActor
@Observable
final class PreviewCoordinator {
    private(set) var image: CGImage?
    private(set) var originalImage: CGImage?
    private(set) var isRendering = false

    /// Changes only when the AVFoundation structure has to change.
    private(set) var compositionSignature: Int = 0

    @ObservationIgnored let compositionEngine = CompositionEngine()
    @ObservationIgnored private let imageEngine = ImageRenderEngine()
    @ObservationIgnored private var session: EditorSession?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var lastRenderedSignature: Int?
    private let logger = FramesLog.render

    func attach(session: EditorSession) {
        self.session = session
        compositionSignature = CompositionEngine.structureSignature(of: session.document)
        refresh()
    }

    /// Called whenever the document may have changed.
    func documentChanged() {
        guard let session else { return }
        let structure = CompositionEngine.structureSignature(of: session.document)
        if structure != compositionSignature {
            compositionSignature = structure
        }
        refresh()
    }

    /// Renders the still preview, debounced and cancellable.
    func refresh(showingOriginal: Bool = false) {
        guard let session, session.document.kind == .photo else { return }
        let document = session.document
        let signature = FrameComposer.visualSignature(of: document, at: 0)
        if !showingOriginal, signature == lastRenderedSignature, image != nil { return }

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            // Short enough that it feels immediate, long enough that a drag
            // does not start a render on every value change.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }

            self.isRendering = true
            defer { self.isRendering = false }

            do {
                let rendered = try await self.imageEngine.renderPreview(
                    document: document,
                    maxPixelSize: EditorCanvasView.previewPixelBudget
                )
                guard !Task.isCancelled else { return }
                self.image = rendered
                self.lastRenderedSignature = signature
            } catch {
                self.logger.error(
                    "Preview render failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// The unedited frame, for press-and-hold comparison. Rendered once and
    /// kept, because the original does not change.
    func prepareOriginal() {
        guard let session, session.document.kind == .photo, originalImage == nil else { return }
        let document = session.document
        Task { [weak self] in
            guard let self else { return }
            self.originalImage = try? await self.imageEngine.renderOriginal(
                document: document,
                maxPixelSize: EditorCanvasView.previewPixelBudget
            )
        }
    }

    func invalidateOverlayImages() {
        Task { await imageEngine.invalidateOverlayImages() }
        lastRenderedSignature = nil
        refresh()
    }

    func purge() {
        renderTask?.cancel()
        image = nil
        originalImage = nil
        lastRenderedSignature = nil
        Task { await imageEngine.purge() }
    }
}
