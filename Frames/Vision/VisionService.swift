import CoreGraphics
import CoreImage
import Foundation
import OSLog
import Vision

/// A face Vision found, in the app's coordinate space.
struct DetectedFace: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Normalized top-left rect in composition space.
    var rect: CGRect
    var confidence: Double
    /// Roll in radians, where available, so a blur can follow a tilted head.
    var roll: Double
}

/// On-device detection and segmentation.
///
/// Everything here is Apple's Vision framework running locally. No frame ever
/// leaves the device, and there is no model to download.
///
/// An actor because Vision handlers are not safe to share across concurrent
/// calls and because serialising requests is what keeps a scrub from queueing
/// twenty simultaneous segmentations.
actor VisionService {
    static let shared = VisionService()

    private let logger = FramesLog.vision
    /// Sequence handler kept alive across frames so object tracking can build
    /// on its previous observation rather than starting cold every time.
    private var trackingHandler = VNSequenceRequestHandler()
    private var trackingObservations: [UUID: VNDetectedObjectObservation] = [:]

    // MARK: - Faces

    /// Detects faces in a frame.
    ///
    /// Ids are assigned by position so that the same face keeps the same id
    /// between two calls on the same frame — Vision itself does not provide a
    /// stable identifier for still detection.
    func detectFaces(in image: CIImage, existing: [DetectedFace] = []) throws -> [DetectedFace] {
        let signpost = FramesLog.signposter.beginInterval("detectFaces")
        defer { FramesLog.signposter.endInterval("detectFaces", signpost) }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations.map { observation in
            let rect = CoordinateSpaceConverter.fromVision(observation.boundingBox)
            let matched = existing.min { lhs, rhs in
                distance(lhs.rect, rect) < distance(rhs.rect, rect)
            }
            let reuseID = (matched.map { distance($0.rect, rect) < 0.12 } ?? false)
                ? matched?.id
                : nil
            return DetectedFace(
                id: reuseID ?? UUID(),
                rect: rect,
                confidence: Double(observation.confidence),
                roll: observation.roll?.doubleValue ?? 0
            )
        }
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    // MARK: - People

    /// Per-person masks, keyed by instance index.
    ///
    /// Falls back to a single combined person mask on hardware or content where
    /// instance separation is unavailable, so "blur this person" still works
    /// rather than failing outright.
    func personMasks(in image: CIImage) throws -> [Int: CIImage] {
        let signpost = FramesLog.signposter.beginInterval("personMasks")
        defer { FramesLog.signposter.endInterval("personMasks", signpost) }

        let handler = VNImageRequestHandler(ciImage: image, options: [:])

        let instanceRequest = VNGeneratePersonInstanceMaskRequest()
        do {
            try handler.perform([instanceRequest])
            if let observation = instanceRequest.results?.first, !observation.allInstances.isEmpty {
                var masks: [Int: CIImage] = [:]
                for instance in observation.allInstances {
                    let buffer = try observation.generateScaledMaskForImage(
                        forInstances: IndexSet(integer: instance),
                        from: handler
                    )
                    masks[instance] = CIImage(cvPixelBuffer: buffer)
                }
                if !masks.isEmpty { return masks }
            }
        } catch {
            logger.notice("Person instance masks unavailable: \(error.localizedDescription, privacy: .public)")
        }

        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([segmentation])
        guard let mask = segmentation.results?.first?.pixelBuffer else { return [:] }
        return [1: CIImage(cvPixelBuffer: mask)]
    }

    /// The foreground subject mask used by Background Blur and Remove
    /// Background.
    func foregroundSubjectMask(in image: CIImage) throws -> CIImage? {
        let signpost = FramesLog.signposter.beginInterval("subjectMask")
        defer { FramesLog.signposter.endInterval("subjectMask", signpost) }

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            return nil
        }
        let buffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        return CIImage(cvPixelBuffer: buffer)
    }

    /// Cuts the subject out of an image, leaving transparency behind it.
    func removeBackground(from image: CIImage) throws -> CIImage {
        guard let mask = try foregroundSubjectMask(in: image) else {
            throw FramesError.visionUnavailable("no foreground subject found")
        }
        let scaledMask = scale(mask, to: image.extent)
        let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: image,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: scaledMask
        ])
        guard let output = blend?.outputImage else {
            throw FramesError.visionUnavailable("could not composite the cut-out")
        }
        return output.cropped(to: image.extent)
    }

    private func scale(_ mask: CIImage, to extent: CGRect) -> CIImage {
        guard mask.extent.width > 0, mask.extent.height > 0, extent.isRenderable else { return mask }
        let scaleX = extent.width / mask.extent.width
        let scaleY = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    }

    // MARK: - Object tracking

    /// Starts a new track from a user-drawn rectangle.
    func beginTracking(_ objectID: UUID, in rect: CGRect) {
        trackingObservations[objectID] = VNDetectedObjectObservation(
            boundingBox: CoordinateSpaceConverter.toVision(rect)
        )
    }

    func endTracking(_ objectID: UUID) {
        trackingObservations.removeValue(forKey: objectID)
        if trackingObservations.isEmpty {
            // A fresh handler drops the accumulated sequence state, which
            // otherwise keeps growing for the life of the session.
            trackingHandler = VNSequenceRequestHandler()
        }
    }

    func resetTracking() {
        trackingObservations.removeAll()
        trackingHandler = VNSequenceRequestHandler()
    }

    /// Advances a track by one frame.
    ///
    /// Returns `nil` when the object was lost, which is the caller's cue to
    /// stop and ask the user to correct the region rather than to keep drawing
    /// a blur over the wrong part of the picture.
    func track(_ objectID: UUID, in image: CIImage) throws -> TrackingSample? {
        guard let previous = trackingObservations[objectID] else { return nil }

        let request = VNTrackObjectRequest(detectedObjectObservation: previous)
        request.trackingLevel = .accurate
        try trackingHandler.perform([request], on: image)

        guard let observation = request.results?.first as? VNDetectedObjectObservation else {
            return nil
        }
        trackingObservations[objectID] = observation

        let confidence = Double(observation.confidence)
        guard confidence > 0.25 else { return nil }

        return TrackingSample(
            time: 0,
            rect: CoordinateSpaceConverter.fromVision(observation.boundingBox),
            confidence: confidence
        )
    }
}
