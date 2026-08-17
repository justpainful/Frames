import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OSLog

/// The custom video compositor.
///
/// Everything the user sees on a video frame is produced here, by the same
/// `FrameComposer` the photo editor uses. Preview and export both run through
/// this class, so an exported file cannot differ from the preview: they are
/// literally the same code path with a different `RenderQuality`.
///
/// A custom compositor rather than `applyingCIFiltersWithHandler` because
/// transitions need two source frames at once, and because clips with different
/// orientations need their transforms applied individually.
final class FramesVideoCompositor: NSObject, AVVideoCompositing {

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    private let renderQueue = DispatchQueue(label: "com.frames.Frames.compositor", qos: .userInitiated)
    private var renderContext: AVVideoCompositionRenderContext?
    private let logger = FramesLog.render

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderQueue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                request.finish(with: FramesError.renderFailed("compositor deallocated"))
                return
            }
            autoreleasepool {
                do {
                    let buffer = try self.render(request)
                    request.finish(withComposedVideoFrame: buffer)
                } catch {
                    self.logger.error("Frame composition failed: \(error.localizedDescription, privacy: .public)")
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Requests are short and already queued in order; nothing to unwind.
    }

    // MARK: - Rendering

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let instruction = request.videoCompositionInstruction as? FramesCompositionInstruction else {
            throw FramesError.renderFailed("unexpected instruction type")
        }
        guard let destination = request.renderContext.newPixelBuffer() else {
            throw FramesError.renderFailed("no destination buffer")
        }

        let plan = instruction.plan
        let time = CMTimeGetSeconds(request.compositionTime)
        let outputRect = CGRect(origin: .zero, size: plan.outputSize)

        let composed: CIImage
        if let incoming = try? sourceImage(for: instruction.placement, request: request) {
            composed = compose(
                source: incoming,
                placement: instruction.placement,
                plan: plan,
                time: time
            )
        } else {
            composed = CIImage(color: .black).cropped(to: outputRect)
        }

        var final = composed

        // A transition needs the outgoing clip's frame as well.
        if let transition = instruction.transition,
           let outgoing = instruction.outgoing,
           transition.isActive,
           let outgoingBuffer = try? sourceImage(for: outgoing, request: request) {
            let outgoingImage = compose(
                source: outgoingBuffer,
                placement: outgoing,
                plan: plan,
                time: time
            )
            let progress = transitionProgress(
                instruction: instruction,
                compositionTime: request.compositionTime
            )
            final = TransitionRenderer.blend(
                from: outgoingImage,
                to: composed,
                transition: transition,
                progress: progress,
                extent: outputRect
            )
        }

        let context = RenderContext.shared.context(for: plan.quality)
        context.render(
            final.cropped(to: outputRect),
            to: destination,
            bounds: outputRect,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
        return destination
    }

    private func compose(
        source: CIImage,
        placement: ClipPlacement,
        plan: VideoRenderPlan,
        time: TimeInterval
    ) -> CIImage {
        var resources = FrameResources()
        resources.overlays = plan.overlays
        resources.backgroundImage = plan.backgroundImage
        if let analyzer = plan.analyzer {
            resources.detections = analyzer.detections(in: source, at: time, document: plan.document)
        }

        return FrameComposer.compose(
            source: source,
            document: plan.document,
            clip: placement.clip,
            time: time,
            outputSize: plan.outputSize,
            resources: resources,
            quality: plan.quality
        )
    }

    /// Pulls a source frame and puts it the right way up.
    ///
    /// A composition can hold clips shot in different orientations, so the
    /// track's preferred transform is applied per clip here rather than once on
    /// the whole composition.
    private func sourceImage(
        for placement: ClipPlacement,
        request: AVAsynchronousVideoCompositionRequest
    ) throws -> CIImage {
        guard let buffer = request.sourceFrame(byTrackID: placement.trackID) else {
            throw FramesError.renderFailed("missing source frame")
        }
        var image = CIImage(cvPixelBuffer: buffer)

        let transform = placement.preferredTransform
        if !transform.isIdentity {
            image = image.transformed(by: transform)
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            ))
        }
        return image
    }

    private func transitionProgress(
        instruction: FramesCompositionInstruction,
        compositionTime: CMTime
    ) -> Double {
        let range = instruction.timeRange
        let duration = CMTimeGetSeconds(range.duration)
        guard duration > 0 else { return 1 }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(compositionTime, range.start))
        return min(max(elapsed / duration, 0), 1)
    }
}
