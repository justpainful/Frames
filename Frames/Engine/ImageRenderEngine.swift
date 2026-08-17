import CoreGraphics
import CoreImage
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Renders still images.
///
/// The photo editor's preview and its export are the same call with different
/// pixel budgets and qualities. There is no separate "export path" that could
/// disagree with what the user was looking at.
actor ImageRenderEngine {
    private let resolver = FrameResourceResolver()
    private let logger = FramesLog.render

    /// Last rendered preview, so a redraw that changes nothing is free.
    private var cachedPreview: (signature: Int, size: Int, image: CGImage)?

    // MARK: - Preview

    func renderPreview(
        document: EditDocument,
        maxPixelSize: Int,
        quality: RenderQuality = .preview
    ) async throws -> CGImage {
        guard document.kind == .photo, let photo = document.photo,
              let asset = document.asset(id: photo.assetID)
        else { throw FramesError.renderFailed("not a photo document") }

        let signature = FrameComposer.visualSignature(of: document, at: 0)
        if let cached = cachedPreview, cached.signature == signature, cached.size == maxPixelSize {
            return cached.image
        }

        let signpost = FramesLog.signposter.beginInterval("renderPhotoPreview")
        defer { FramesLog.signposter.endInterval("renderPhotoPreview", signpost) }

        let url = SessionPaths.mediaURL(for: asset.fileName)
        let decoded = try await ImageLoader.shared.image(at: url, maxPixelSize: maxPixelSize)
        let source = CIImage(cgImage: decoded)

        let outputSize = outputSize(for: document, source: source, budget: CGFloat(maxPixelSize))
        let resources = await resolver.resources(
            for: document,
            sourceImage: source,
            time: 0,
            outputSize: outputSize,
            quality: quality
        )

        let composed = FrameComposer.compose(
            source: source,
            document: document,
            clip: nil,
            time: 0,
            outputSize: outputSize,
            resources: resources,
            quality: quality
        )

        guard let image = RenderContext.shared.context(for: quality).createCGImage(
            composed,
            from: CGRect(origin: .zero, size: outputSize)
        ) else {
            throw FramesError.renderFailed("Core Image produced no output")
        }

        cachedPreview = (signature, maxPixelSize, image)
        return image
    }

    /// The unedited frame, for the press-and-hold comparison.
    func renderOriginal(document: EditDocument, maxPixelSize: Int) async throws -> CGImage {
        guard document.kind == .photo, let photo = document.photo,
              let asset = document.asset(id: photo.assetID)
        else { throw FramesError.renderFailed("not a photo document") }

        let url = SessionPaths.mediaURL(for: asset.fileName)
        let decoded = try await ImageLoader.shared.image(at: url, maxPixelSize: maxPixelSize)
        let source = CIImage(cgImage: decoded)
        let outputSize = outputSize(for: document, source: source, budget: CGFloat(maxPixelSize))

        let composed = FrameComposer.composeOriginal(
            source: source,
            document: document,
            clip: nil,
            outputSize: outputSize,
            quality: .preview
        )
        guard let image = RenderContext.shared.preview.createCGImage(
            composed,
            from: CGRect(origin: .zero, size: outputSize)
        ) else {
            throw FramesError.renderFailed("Core Image produced no output")
        }
        return image
    }

    // MARK: - Export

    /// Renders at full quality and encodes to a file.
    func export(
        document: EditDocument,
        to url: URL,
        settings: ExportSettings
    ) async throws {
        guard document.kind == .photo, let photo = document.photo,
              let asset = document.asset(id: photo.assetID)
        else { throw FramesError.exportFailed("not a photo document") }

        let signpost = FramesLog.signposter.beginInterval("exportPhoto")
        defer { FramesLog.signposter.endInterval("exportPhoto", signpost) }

        let sourceURL = SessionPaths.mediaURL(for: asset.fileName)
        let decoded = try await ImageLoader.shared.fullResolutionImage(at: sourceURL)
        let source = CIImage(cgImage: decoded)

        let longEdge = settings.resolution.longEdge(sourceLongEdge: max(asset.displaySize.width, asset.displaySize.height))
        let outputSize = outputSize(for: document, source: source, budget: longEdge)

        let resources = await resolver.resources(
            for: document,
            sourceImage: source,
            time: 0,
            outputSize: outputSize,
            quality: .final
        )
        let composed = FrameComposer.compose(
            source: source,
            document: document,
            clip: nil,
            time: 0,
            outputSize: outputSize,
            resources: resources,
            quality: .final
        )

        let context = RenderContext.shared.export
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rect = CGRect(origin: .zero, size: outputSize)

        do {
            switch settings.stillFormat {
            case .heic:
                try context.writeHEIFRepresentation(
                    of: composed.cropped(to: rect),
                    to: url,
                    format: .RGBA8,
                    colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                                settings.quality.stillCompressionQuality]
                )
            case .jpeg:
                try context.writeJPEGRepresentation(
                    of: composed.cropped(to: rect),
                    to: url,
                    colorSpace: colorSpace,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                                settings.quality.stillCompressionQuality]
                )
            case .png:
                try context.writePNGRepresentation(
                    of: composed.cropped(to: rect),
                    to: url,
                    format: .RGBA8,
                    colorSpace: colorSpace
                )
            }
        } catch {
            logger.error("Still export failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - Geometry

    /// The pixel size the composition renders at, honouring the output aspect
    /// and a pixel budget for the long edge.
    private func outputSize(for document: EditDocument, source: CIImage, budget: CGFloat) -> CGSize {
        let cropped = GeometryRenderer.applyCrop(document.photo?.crop ?? .identity, to: source)
        let base = cropped.extent.isRenderable ? cropped.extent.size : source.extent.size

        let aspect: CGFloat
        if let explicit = document.outputAspect.ratio {
            aspect = explicit
        } else {
            aspect = base.height > 0 ? base.width / base.height : 1
        }

        let longEdge = min(max(budget, 64), 16384)
        if aspect >= 1 {
            return CGSize(width: longEdge.rounded(), height: (longEdge / aspect).rounded())
        }
        return CGSize(width: (longEdge * aspect).rounded(), height: longEdge.rounded())
    }

    // MARK: - Housekeeping

    func invalidateCaches() {
        cachedPreview = nil
    }

    func purge() async {
        cachedPreview = nil
        await resolver.purge()
    }

    func invalidateDetections() async {
        cachedPreview = nil
        await resolver.invalidateDetections()
    }

    func invalidateOverlayImages() async {
        cachedPreview = nil
        await resolver.invalidateOverlayImages()
    }
}
