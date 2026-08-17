import CoreGraphics
import CoreImage
import Foundation
import OSLog

/// Resolves the images and detections a frame needs.
///
/// Kept separate from the composer so the composer can stay synchronous: all
/// the asynchronous, expensive and cacheable work happens here, once, and the
/// results are handed over as plain values.
actor FrameResourceResolver {
    private let logger = FramesLog.render

    /// Decoded overlay source images, by asset id.
    private var imageCache: [UUID: CIImage] = [:]
    /// Background-removed cut-outs, by overlay id.
    private var cutoutCache: [UUID: CIImage] = [:]
    /// Rasterised drawings, keyed by drawing id and the size they were drawn at.
    private var drawingCache: [DrawingKey: CIImage] = [:]
    /// Detections, keyed by the frame they were computed for.
    private var detectionCache: [DetectionKey: DetectionContext] = [:]
    private var detectionOrder: [DetectionKey] = []
    private let detectionCacheLimit = 24

    private struct DrawingKey: Hashable {
        let id: UUID
        let width: Int
        let height: Int
        let dataHash: Int
    }

    private struct DetectionKey: Hashable {
        let frameHash: Int
        let requirements: DetectionRequirements
    }

    // MARK: - Entry point

    func resources(
        for document: EditDocument,
        sourceImage: CIImage,
        time: TimeInterval,
        outputSize: CGSize,
        quality: RenderQuality
    ) async -> FrameResources {
        var resources = FrameResources()

        resources.overlays.images = await loadOverlayImages(for: document)
        resources.overlays.cutouts = await loadCutouts(for: document)
        resources.overlays.drawings = rasteriseDrawings(for: document, size: outputSize)

        if let backgroundID = document.background.imageAssetID,
           document.background.fill == .image {
            resources.backgroundImage = await image(forAsset: backgroundID, in: document)
        }

        let requirements = FrameComposer.detectionRequirements(for: document)
        if !requirements.isEmpty {
            resources.detections = await detections(
                for: requirements,
                in: sourceImage,
                document: document,
                time: time,
                quality: quality
            )
        }

        return resources
    }

    // MARK: - Overlay images

    private func loadOverlayImages(for document: EditDocument) async -> [UUID: CIImage] {
        var result: [UUID: CIImage] = [:]
        for overlay in document.imageOverlays {
            if let image = await image(forAsset: overlay.assetID, in: document) {
                result[overlay.assetID] = image
            }
        }
        return result
    }

    private func image(forAsset assetID: UUID, in document: EditDocument) async -> CIImage? {
        if let cached = imageCache[assetID] { return cached }
        guard let asset = document.asset(id: assetID) else { return nil }
        let url = SessionPaths.mediaURL(for: asset.fileName)
        do {
            // Overlays are composited at composition scale, so a full-resolution
            // decode of a 48-megapixel sticker would be wasted work.
            let decoded = try await ImageLoader.shared.image(at: url, maxPixelSize: 3000)
            let image = CIImage(cgImage: decoded)
            imageCache[assetID] = image
            return image
        } catch {
            logger.error("Overlay image failed to load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func loadCutouts(for document: EditDocument) async -> [UUID: CIImage] {
        var result: [UUID: CIImage] = [:]
        for overlay in document.imageOverlays where overlay.isBackgroundRemoved {
            if let cached = cutoutCache[overlay.id] {
                result[overlay.id] = cached
                continue
            }
            guard let fileName = overlay.cutoutFileName else { continue }
            let url = SessionPaths.cutoutURL(for: fileName)
            guard let source = CIImage(contentsOf: url) else { continue }
            cutoutCache[overlay.id] = source
            result[overlay.id] = source
        }
        return result
    }

    private func rasteriseDrawings(for document: EditDocument, size: CGSize) -> [UUID: CIImage] {
        guard size.width > 0, size.height > 0 else { return [:] }
        var result: [UUID: CIImage] = [:]
        for drawing in document.drawings where !drawing.pencilData.isEmpty {
            let key = DrawingKey(
                id: drawing.id,
                width: Int(size.width),
                height: Int(size.height),
                dataHash: drawing.pencilData.hashValue
            )
            if let cached = drawingCache[key] {
                result[drawing.id] = cached
                continue
            }
            guard let raster = OverlayCompositor.rasterise(drawing, size: size) else { continue }
            drawingCache[key] = raster
            result[drawing.id] = raster
        }
        return result
    }

    // MARK: - Detections

    private func detections(
        for requirements: DetectionRequirements,
        in image: CIImage,
        document: EditDocument,
        time: TimeInterval,
        quality: RenderQuality
    ) async -> DetectionContext {
        // Quantising the frame identity means a scrub within the same frame
        // reuses the previous detection instead of re-running Vision.
        let key = DetectionKey(
            frameHash: frameHash(image: image, time: time),
            requirements: requirements
        )
        if let cached = detectionCache[key] { return cached }

        var context = DetectionContext()

        // Tracked objects come from the document, not from Vision: the track was
        // computed once, when the user asked for it, and cached.
        for objectID in requirements.trackedObjectIDs {
            if let object = document.trackedObjects.first(where: { $0.id == objectID }),
               let rect = object.rect(at: time) {
                context.trackedRects[objectID] = rect
            }
        }

        // Vision at full preview resolution is wasted work; segmentation and
        // face detection are both stable at a much smaller size.
        let analysisImage = downsampledForAnalysis(image)

        if requirements.needsFaces {
            do {
                let faces = try await VisionService.shared.detectFaces(in: analysisImage)
                // Blur regions reference faces by id; the ids come from the
                // detection pass the user tapped on, so match by position.
                context.faces = matchFaces(faces, to: document)
            } catch {
                logger.notice("Face detection failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if requirements.needsPersonInstances {
            do {
                context.personMasks = try await VisionService.shared.personMasks(in: analysisImage)
            } catch {
                logger.notice("Person masks failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if requirements.needsSubject {
            do {
                context.subjectMask = try await VisionService.shared.foregroundSubjectMask(in: analysisImage)
            } catch {
                logger.notice("Subject mask failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        store(context, for: key)
        return context
    }

    /// Blur regions store the id of the face the user tapped. Re-detection
    /// produces fresh ids, so each requested face is matched to the nearest
    /// detection, which is what makes a face blur survive a scrub.
    private func matchFaces(_ faces: [DetectedFace], to document: EditDocument) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        var available = faces

        var requested: [(id: UUID, hint: CGRect)] = []
        for region in document.blurRegions {
            if case .face(let detectionID) = region.mask?.shape {
                requested.append((detectionID, region.mask?.boundingBox ?? .zero))
            }
        }
        for adjustment in document.selectiveAdjustments {
            if case .face(let detectionID) = adjustment.mask.shape {
                requested.append((detectionID, adjustment.mask.boundingBox))
            }
        }

        for request in requested {
            guard !available.isEmpty else { break }
            let nearestIndex = available.indices.min { lhs, rhs in
                centreDistance(available[lhs].rect, request.hint)
                    < centreDistance(available[rhs].rect, request.hint)
            }
            guard let index = nearestIndex else { break }
            result[request.id] = available[index].rect
            available.remove(at: index)
        }

        // Also expose every detection under its own id, so newly detected faces
        // are selectable without another pass.
        for face in available {
            result[face.id] = face.rect
        }
        return result
    }

    private func centreDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private func downsampledForAnalysis(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.isRenderable else { return image }
        let longEdge = max(extent.width, extent.height)
        let target: CGFloat = 1024
        guard longEdge > target else { return image }
        let scale = target / longEdge
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func frameHash(image: CIImage, time: TimeInterval) -> Int {
        var hasher = Hasher()
        hasher.combine(image.extent.width)
        hasher.combine(image.extent.height)
        hasher.combine(Int((time * 30).rounded()))
        return hasher.finalize()
    }

    private func store(_ context: DetectionContext, for key: DetectionKey) {
        detectionCache[key] = context
        detectionOrder.append(key)
        while detectionOrder.count > detectionCacheLimit {
            let evicted = detectionOrder.removeFirst()
            detectionCache.removeValue(forKey: evicted)
        }
    }

    // MARK: - Invalidation

    func invalidateOverlayImages() {
        imageCache.removeAll()
        cutoutCache.removeAll()
    }

    func invalidateCutout(for overlayID: UUID) {
        cutoutCache.removeValue(forKey: overlayID)
    }

    func invalidateDetections() {
        detectionCache.removeAll()
        detectionOrder.removeAll()
    }

    func purge() {
        imageCache.removeAll()
        cutoutCache.removeAll()
        drawingCache.removeAll()
        invalidateDetections()
    }
}
