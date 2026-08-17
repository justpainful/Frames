import CoreImage
import Foundation

/// What Portrait mode carries from one frame to the next.
///
/// Everything in here is a *measurement or a decision*, never a picture of a
/// previous frame. Blending old frames into new ones produces ghosting during
/// motion; blending old *decisions* into new ones produces a filter that keeps
/// its character while the picture moves, which is the difference between
/// footage that looks like it came from one camera and footage that looks
/// re-graded thirty times a second.
///
/// The single exception is the person mask, which is a measurement too: Vision
/// re-segments each frame and its boundary moves by a pixel or two even when
/// nobody has moved, so the mask is averaged with the previous one for the same
/// reason the scalars are.
///
/// Concurrency: one instance belongs to one render pass and is only ever
/// touched from the queue driving that pass — the compositor's queue for video,
/// the main actor for a still. That is what makes the unchecked conformance
/// true rather than merely asserted. `FrameAnalyzer` is safe for the same
/// reason.
final class PortraitTemporalState: @unchecked Sendable {
    init() {}

    /// The composition time of the last frame processed, used to notice a seek.
    private(set) var lastTime: TimeInterval?

    /// The amounts the previous frame resolved, which this frame is smoothed
    /// towards.
    var amounts: PortraitProcessor.Amounts?

    /// The last measured average luminance, and when it was measured. Held so
    /// the measurement does not have to run on every frame.
    var luminance: Double?
    var luminanceTime: TimeInterval?

    /// The previous frame's feathered person mask, in composition pixel space.
    var personMask: CIImage?

    func advance(to time: TimeInterval) {
        lastTime = time
    }

    /// Drops everything held. Called when the playhead jumps, because after a
    /// seek the held values describe a different part of the media and holding
    /// onto them would drag the wrong exposure into the new frame.
    func reset() {
        lastTime = nil
        amounts = nil
        luminance = nil
        luminanceTime = nil
        personMask = nil
    }
}
