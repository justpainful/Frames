import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// Everything the video compositor needs, resolved once before playback or
/// export starts.
///
/// `AVVideoCompositing` runs on AVFoundation's own queue and cannot await
/// anything, so all the asynchronous work — decoding overlay images, cutting
/// out backgrounds, rasterising drawings — happens here first and is handed
/// over as immutable values.
final class VideoRenderPlan: @unchecked Sendable {
    let document: EditDocument
    let outputSize: CGSize
    let overlays: OverlayResources
    let backgroundImage: CIImage?
    let quality: RenderQuality
    /// Set when a blur or selective adjustment needs Vision on every frame.
    let analyzer: FrameAnalyzer?

    init(
        document: EditDocument,
        outputSize: CGSize,
        overlays: OverlayResources,
        backgroundImage: CIImage?,
        quality: RenderQuality,
        analyzer: FrameAnalyzer?
    ) {
        self.document = document
        self.outputSize = outputSize
        self.overlays = overlays
        self.backgroundImage = backgroundImage
        self.quality = quality
        self.analyzer = analyzer
    }
}

/// One clip's placement in the composition.
struct ClipPlacement: Sendable {
    let clip: VideoClip
    /// Where the clip sits on the timeline.
    let timelineRange: TimeRange
    /// The source track's preferred transform, applied by the compositor so
    /// clips of different orientations can share one composition.
    let preferredTransform: CGAffineTransform
    /// Natural size of the source track, before its transform.
    let naturalSize: CGSize
    /// Which composition track the clip was laid onto.
    let trackID: CMPersistentTrackID
}

/// A video composition instruction that carries the plan with it.
///
/// AVFoundation instantiates the compositor itself, so state has to travel
/// through the instruction rather than through the compositor's initialiser.
final class FramesCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let plan: VideoRenderPlan
    /// The clip visible for this instruction's range.
    let placement: ClipPlacement
    /// The outgoing clip, when this range is a transition.
    let outgoing: ClipPlacement?
    let transition: Transition?

    init(
        timeRange: CMTimeRange,
        plan: VideoRenderPlan,
        placement: ClipPlacement,
        outgoing: ClipPlacement? = nil,
        transition: Transition? = nil
    ) {
        self.timeRange = timeRange
        self.plan = plan
        self.placement = placement
        self.outgoing = outgoing
        self.transition = transition
        var ids: [NSValue] = [NSNumber(value: placement.trackID)]
        if let outgoing {
            ids.append(NSNumber(value: outgoing.trackID))
        }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}
