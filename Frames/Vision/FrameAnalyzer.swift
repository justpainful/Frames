import CoreGraphics
import CoreImage
import Foundation
import OSLog
import Vision

/// Synchronous Vision for the video compositor.
///
/// `AVVideoCompositing` cannot await, so the actor-based `VisionService` is not
/// usable from inside a frame request. This class does the same work
/// synchronously and is only ever touched from one queue at a time — the
/// compositor's — which is what makes that safe.
///
/// It also caches aggressively: segmentation is expensive enough that running
/// it on every frame of a 60 fps export would dominate the render, so results
/// are reused across a short window of frames where the picture barely changes.
final class FrameAnalyzer: @unchecked Sendable {
    private let requirements: DetectionRequirements
    private let logger = FramesLog.vision

    private var cachedTime: TimeInterval = -1
    private var cached: DetectionContext = .empty
    /// How stale a detection is allowed to be, in seconds of composition time.
    private let staleness: TimeInterval

    init(requirements: DetectionRequirements, staleness: TimeInterval = 1.0 / 6.0) {
        self.requirements = requirements
        self.staleness = staleness
    }

    /// Detections for a frame, reusing the previous result when the playhead
    /// has barely moved.
    func detections(
        in image: CIImage,
        at time: TimeInterval,
        document: EditDocument
    ) -> DetectionContext {
        var context = DetectionContext()

        // Tracked objects are read from the document, never re-detected: the
        // track was computed once when the user asked for it.
        for objectID in requirements.trackedObjectIDs {
            if let object = document.trackedObjects.first(where: { $0.id == objectID }),
               let rect = object.rect(at: time) {
                context.trackedRects[objectID] = rect
            }
        }

        let needsVision = requirements.needsFaces
            || requirements.needsPersonInstances
            || requirements.needsSubject
        guard needsVision else { return context }

        if cachedTime >= 0, abs(time - cachedTime) < staleness {
            context.faces = cached.faces
            context.personMasks = cached.personMasks
            context.subjectMask = cached.subjectMask
            return context
        }

        let signpost = FramesLog.signposter.beginInterval("frameAnalysis")
        defer { FramesLog.signposter.endInterval("frameAnalysis", signpost) }

        let analysis = downsampled(image)
        let handler = VNImageRequestHandler(ciImage: analysis, options: [:])

        if requirements.needsFaces {
            let request = VNDetectFaceRectanglesRequest()
            do {
                try handler.perform([request])
                context.faces = matchedFaces(request.results ?? [], document: document, time: time)
            } catch {
                logger.notice("Face detection failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if requirements.needsPersonInstances {
            context.personMasks = personMasks(handler: handler)
        }

        if requirements.needsSubject {
            context.subjectMask = subjectMask(handler: handler)
        }

        cachedTime = time
        cached = DetectionContext(
            faces: context.faces,
            personMasks: context.personMasks,
            subjectMask: context.subjectMask,
            trackedRects: [:]
        )
        return context
    }

    // MARK: - Requests

    private func personMasks(handler: VNImageRequestHandler) -> [Int: CIImage] {
        let request = VNGeneratePersonInstanceMaskRequest()
        do {
            try handler.perform([request])
            if let observation = request.results?.first, !observation.allInstances.isEmpty {
                var masks: [Int: CIImage] = [:]
                for instance in observation.allInstances {
                    if let buffer = try? observation.generateScaledMaskForImage(
                        forInstances: IndexSet(integer: instance),
                        from: handler
                    ) {
                        masks[instance] = CIImage(cvPixelBuffer: buffer)
                    }
                }
                if !masks.isEmpty { return masks }
            }
        } catch {
            logger.notice("Person instances unavailable: \(error.localizedDescription, privacy: .public)")
        }

        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .fast
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([segmentation])) != nil,
              let buffer = segmentation.results?.first?.pixelBuffer
        else { return [:] }
        return [1: CIImage(cvPixelBuffer: buffer)]
    }

    private func subjectMask(handler: VNImageRequestHandler) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                  forInstances: observation.allInstances,
                  from: handler
              )
        else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// Matches this frame's detections to the face ids the document refers to.
    ///
    /// On video the user taps a face once; every later frame has to decide
    /// which of that frame's detections is the same face. Nearest-centre
    /// matching against the previous frame's answer is enough for the motion
    /// between two frames, and the cache means it only runs a few times a
    /// second.
    private func matchedFaces(
        _ observations: [VNFaceObservation],
        document: EditDocument,
        time: TimeInterval
    ) -> [UUID: CGRect] {
        var available = observations.map { CoordinateSpaceConverter.fromVision($0.boundingBox) }
        var result: [UUID: CGRect] = [:]

        var requested: [(id: UUID, hint: CGRect)] = []
        for region in document.blurRegions {
            if case .face(let detectionID) = region.mask?.shape {
                let hint = cached.faces[detectionID] ?? region.mask?.boundingBox(at: time) ?? .zero
                requested.append((detectionID, hint))
            }
        }
        for adjustment in document.selectiveAdjustments {
            if case .face(let detectionID) = adjustment.mask.shape {
                let hint = cached.faces[detectionID] ?? adjustment.mask.boundingBox(at: time)
                requested.append((detectionID, hint))
            }
        }

        for request in requested {
            guard !available.isEmpty else { break }
            let index = available.indices.min {
                distance(available[$0], request.hint) < distance(available[$1], request.hint)
            }
            guard let index else { break }
            result[request.id] = available[index]
            available.remove(at: index)
        }
        return result
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private func downsampled(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.isRenderable else { return image }
        let longEdge = max(extent.width, extent.height)
        let target: CGFloat = 768
        guard longEdge > target else { return image }
        let scale = target / longEdge
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}
