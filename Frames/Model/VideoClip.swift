import CoreGraphics
import Foundation

/// One segment of video on the timeline.
///
/// A clip never owns pixels. It points at a `SourceAsset` and a range inside
/// it, which is what makes trim, split and range removal cheap, lossless and
/// undoable: they only ever rewrite these numbers.
///
/// A freeze frame is modelled as a clip whose `freezeDuration` is set — the
/// same clip type, holding a single source time for a while. That keeps every
/// timeline operation (trim, split, remove range, reorder) working on frozen
/// clips without a single special case.
struct VideoClip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var assetID: UUID
    /// The portion of the source that plays, in source time. For a frozen clip
    /// this collapses to the held instant at `source.start`.
    var source: TimeRange
    /// Playback rate. 1 is normal; the timeline duration is
    /// `source.duration / speed`.
    var speed: Double
    var isReversed: Bool
    /// When set, the clip holds the frame at `source.start` for this long.
    var freezeDuration: TimeInterval?
    /// 0...2, where 1 is unity gain, applied to the clip's own audio.
    var volume: Double
    var isMuted: Bool
    var crop: CropState
    /// Reframing inside the output rect — pan and zoom, not cropping.
    var transform: LayerTransform
    /// A transition into this clip, overlapping the previous one.
    var transitionIn: Transition
    var keyframes: KeyframeSet

    init(
        id: UUID = UUID(),
        assetID: UUID,
        source: TimeRange,
        speed: Double = 1,
        isReversed: Bool = false,
        freezeDuration: TimeInterval? = nil,
        volume: Double = 1,
        isMuted: Bool = false,
        crop: CropState = .identity,
        transform: LayerTransform = .identity,
        transitionIn: Transition = .none,
        keyframes: KeyframeSet = KeyframeSet()
    ) {
        self.id = id
        self.assetID = assetID
        self.source = source
        self.speed = min(max(speed, VideoClip.minimumSpeed), VideoClip.maximumSpeed)
        self.isReversed = isReversed
        self.freezeDuration = freezeDuration.map { max($0, VideoClip.minimumDuration) }
        self.volume = min(max(volume, 0), 2)
        self.isMuted = isMuted
        self.crop = crop
        self.transform = transform
        self.transitionIn = transitionIn
        self.keyframes = keyframes
    }

    static let minimumSpeed: Double = 0.1
    static let maximumSpeed: Double = 8
    /// The shortest a clip is allowed to become through trimming. Below about
    /// two frames at 30 fps, trimming stops being editing and starts being an
    /// accident.
    static let minimumDuration: TimeInterval = 0.07

    var isFrozen: Bool { freezeDuration != nil }

    /// Duration this clip occupies on the timeline.
    var timelineDuration: TimeInterval {
        if let freezeDuration { return max(freezeDuration, VideoClip.minimumDuration) }
        return source.duration / max(speed, VideoClip.minimumSpeed)
    }

    /// Maps a time on the timeline, relative to this clip's start, to a time in
    /// the source asset. Accounts for speed, reversal and freezing.
    func sourceTime(forOffset offset: TimeInterval) -> TimeInterval {
        guard !isFrozen else { return source.start }
        let clamped = min(max(offset, 0), timelineDuration)
        let scaled = min(clamped * max(speed, VideoClip.minimumSpeed), source.duration)
        return isReversed ? source.end - scaled : source.start + scaled
    }

    /// Effective gain at an offset into the clip, including mute and any volume
    /// keyframes.
    func gain(at offset: TimeInterval) -> Double {
        guard !isMuted else { return 0 }
        return min(max(keyframes.value(.volume, at: offset, fallback: volume), 0), 2)
    }

    /// The output aspect ratio this clip produces from a source of the given
    /// ratio, once its crop is applied.
    func outputAspectRatio(sourceAspectRatio: CGFloat) -> CGFloat {
        crop.outputAspectRatio(sourceAspectRatio: sourceAspectRatio)
    }

    // MARK: - Trimming primitives
    //
    // Both take a delta expressed in *timeline* seconds, because that is what
    // the user is dragging. Converting to source time in one place keeps speed
    // and reversal from leaking into every call site.

    /// Removes `delta` timeline seconds from the start of the clip.
    /// Returns false and leaves the clip untouched if that would take it below
    /// the minimum duration.
    @discardableResult
    mutating func trimHead(by delta: TimeInterval) -> Bool {
        guard delta > 0 else { return false }
        guard timelineDuration - delta >= VideoClip.minimumDuration else { return false }
        if freezeDuration != nil {
            freezeDuration = timelineDuration - delta
            return true
        }
        let sourceDelta = delta * max(speed, VideoClip.minimumSpeed)
        if isReversed {
            source.duration -= sourceDelta
        } else {
            source.start += sourceDelta
            source.duration -= sourceDelta
        }
        keyframes.shift(by: -delta)
        return true
    }

    /// Removes `delta` timeline seconds from the end of the clip.
    @discardableResult
    mutating func trimTail(by delta: TimeInterval) -> Bool {
        guard delta > 0 else { return false }
        guard timelineDuration - delta >= VideoClip.minimumDuration else { return false }
        if freezeDuration != nil {
            freezeDuration = timelineDuration - delta
            return true
        }
        let sourceDelta = delta * max(speed, VideoClip.minimumSpeed)
        if isReversed {
            source.start += sourceDelta
            source.duration -= sourceDelta
        } else {
            source.duration -= sourceDelta
        }
        return true
    }

    /// Splits the clip at `offset` timeline seconds from its start, returning
    /// the trailing half. `nil` when the offset is too close to either edge.
    func splitting(atOffset offset: TimeInterval) -> (head: VideoClip, tail: VideoClip)? {
        guard offset >= VideoClip.minimumDuration,
              timelineDuration - offset >= VideoClip.minimumDuration
        else { return nil }

        var head = self
        var tail = self
        tail.id = UUID()
        // A split never inherits a transition on the new inner edge.
        tail.transitionIn = .none

        if freezeDuration != nil {
            head.freezeDuration = offset
            tail.freezeDuration = timelineDuration - offset
            tail.keyframes.shift(by: -offset)
            return (head, tail)
        }

        let sourceOffset = offset * max(speed, VideoClip.minimumSpeed)
        if isReversed {
            head.source = TimeRange(start: source.end - sourceOffset, duration: sourceOffset)
            tail.source = TimeRange(start: source.start, duration: source.duration - sourceOffset)
        } else {
            head.source = TimeRange(start: source.start, duration: sourceOffset)
            tail.source = TimeRange(start: source.start + sourceOffset, duration: source.duration - sourceOffset)
        }
        tail.keyframes.shift(by: -offset)
        return (head, tail)
    }

    /// A frozen clip taken from `sourceTime`.
    static func freeze(
        assetID: UUID,
        sourceTime: TimeInterval,
        duration: TimeInterval = 1.0,
        inheriting template: VideoClip? = nil
    ) -> VideoClip {
        var clip = VideoClip(
            assetID: assetID,
            source: TimeRange(start: sourceTime, duration: 0),
            freezeDuration: duration
        )
        if let template {
            clip.crop = template.crop
            clip.transform = template.transform
            clip.volume = 0
            clip.isMuted = true
        } else {
            clip.isMuted = true
        }
        return clip
    }
}
