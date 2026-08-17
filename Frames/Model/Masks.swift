import CoreGraphics
import Foundation

/// The shapes a mask can take.
///
/// One mask type serves every tool that needs to restrict an effect to part of
/// the frame: blur, selective adjustment, effects and overlays. Adding a shape
/// here makes it available everywhere at once, which is why the shape is data
/// rather than a per-tool special case.
enum MaskShape: Codable, Hashable, Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: Double)
    case ellipse
    /// Angle in radians; the gradient runs perpendicular to it.
    case linearGradient(angle: Double)
    case radialGradient
    /// Normalized points in composition space, closed automatically.
    case freeform(points: [CGPoint])
    /// A person instance found by Vision. `instance` is the instance index
    /// within the segmentation result.
    case person(instance: Int)
    /// A face found by Vision, referenced by the detection's stable identifier.
    case face(detectionID: UUID)
    /// Whatever Vision considers the foreground subject.
    case foregroundSubject

    var displayName: String {
        switch self {
        case .rectangle: String(localized: "Rectangle", comment: "Mask shape")
        case .roundedRectangle: String(localized: "Rounded Rectangle", comment: "Mask shape")
        case .ellipse: String(localized: "Ellipse", comment: "Mask shape")
        case .linearGradient: String(localized: "Linear Gradient", comment: "Mask shape")
        case .radialGradient: String(localized: "Radial Gradient", comment: "Mask shape")
        case .freeform: String(localized: "Freeform", comment: "Mask shape")
        case .person: String(localized: "Person", comment: "Mask shape")
        case .face: String(localized: "Face", comment: "Mask shape")
        case .foregroundSubject: String(localized: "Subject", comment: "Mask shape")
        }
    }

    var symbolName: String {
        switch self {
        case .rectangle: "rectangle"
        case .roundedRectangle: "rectangle.roundedtop"
        case .ellipse: "oval"
        case .linearGradient: "square.righthalf.filled"
        case .radialGradient: "circle.circle"
        case .freeform: "scribble"
        case .person: "person.fill"
        case .face: "face.smiling"
        case .foregroundSubject: "person.and.background.dotted"
        }
    }

    /// True when the shape is produced by Vision rather than drawn by hand.
    var isDetected: Bool {
        switch self {
        case .person, .face, .foregroundSubject: true
        default: false
        }
    }

    /// True when the shape has geometry the user can drag on the canvas.
    var isManipulable: Bool { !isDetected }
}

/// A mask: a shape plus how softly and how strongly it applies.
struct MaskDefinition: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var shape: MaskShape
    /// Centre, rotation and opacity of the shape in composition space.
    var transform: LayerTransform
    /// Normalized size of the shape's bounding box before `transform.scale`.
    var size: CGSize
    /// 0 is a hard edge, 1 is a very soft edge.
    var feather: Double
    var isInverted: Bool
    /// When set, the mask follows a tracked object instead of staying put.
    var trackedObjectID: UUID?
    var keyframes: KeyframeSet

    init(
        id: UUID = UUID(),
        shape: MaskShape = .roundedRectangle(cornerRadius: 0.08),
        transform: LayerTransform = .identity,
        size: CGSize = CGSize(width: 0.4, height: 0.28),
        feather: Double = 0.25,
        isInverted: Bool = false,
        trackedObjectID: UUID? = nil,
        keyframes: KeyframeSet = KeyframeSet()
    ) {
        self.id = id
        self.shape = shape
        self.transform = transform
        self.size = size
        self.feather = feather
        self.isInverted = isInverted
        self.trackedObjectID = trackedObjectID
        self.keyframes = keyframes
    }

    /// The axis-aligned bounding box of the mask in normalized composition
    /// space, ignoring rotation. Used for hit testing and handle placement.
    var boundingBox: CGRect {
        let width = size.width * transform.scale
        let height = size.height * transform.scale
        return CGRect(
            x: transform.position.x - width / 2,
            y: transform.position.y - height / 2,
            width: width,
            height: height
        )
    }

    func boundingBox(at time: TimeInterval) -> CGRect {
        let animated = transform.evaluated(with: keyframes, at: time)
        let width = size.width * animated.scale
        let height = size.height * animated.scale
        return CGRect(
            x: animated.position.x - width / 2,
            y: animated.position.y - height / 2,
            width: width,
            height: height
        )
    }

    mutating func normalize() {
        transform.clampToUsableBounds()
        feather = min(max(feather, 0), 1)
        size.width = min(max(size.width, 0.02), 4)
        size.height = min(max(size.height, 0.02), 4)
    }
}

/// One frame of a tracking result.
struct TrackingSample: Codable, Hashable, Sendable {
    /// Timeline time in seconds.
    var time: TimeInterval
    /// Normalized top-left rect in composition space.
    var rect: CGRect
    var confidence: Double
}

/// An object the user asked Frames to follow through the video.
///
/// Samples are cached in the document so re-opening a session does not mean
/// re-running Vision over the whole clip, and so preview and export agree
/// exactly on where a tracked blur sits at any given moment.
struct TrackedObject: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var label: String
    private(set) var samples: [TrackingSample]
    /// Time after which tracking confidence collapsed and the user was asked to
    /// correct it. `nil` while tracking is healthy for the whole range.
    var lostConfidenceAt: TimeInterval?

    init(
        id: UUID = UUID(),
        label: String = "",
        samples: [TrackingSample] = [],
        lostConfidenceAt: TimeInterval? = nil
    ) {
        self.id = id
        self.label = label
        self.samples = samples.sorted { $0.time < $1.time }
        self.lostConfidenceAt = lostConfidenceAt
    }

    var isEmpty: Bool { samples.isEmpty }

    var timeRange: TimeRange? {
        guard let first = samples.first, let last = samples.last else { return nil }
        return TimeRange(start: first.time, end: last.time)
    }

    mutating func replaceSamples(_ newSamples: [TrackingSample]) {
        samples = newSamples.sorted { $0.time < $1.time }
    }

    mutating func append(_ sample: TrackingSample) {
        samples.append(sample)
        samples.sort { $0.time < $1.time }
    }

    /// Removes every sample at or after `time`, used when the user corrects a
    /// drifted track and re-runs from that point.
    mutating func truncate(from time: TimeInterval) {
        samples.removeAll { $0.time >= time }
    }

    /// Linearly interpolated rect at an arbitrary time, clamped at both ends.
    func rect(at time: TimeInterval) -> CGRect? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return first.rect }
        if time >= last.time { return last.rect }

        var lower = first
        var upper = last
        for sample in samples {
            if sample.time <= time { lower = sample }
            if sample.time >= time { upper = sample; break }
        }
        let span = upper.time - lower.time
        guard span > 0 else { return upper.rect }
        let t = (time - lower.time) / span
        return CGRect(
            x: lower.rect.origin.x + (upper.rect.origin.x - lower.rect.origin.x) * t,
            y: lower.rect.origin.y + (upper.rect.origin.y - lower.rect.origin.y) * t,
            width: lower.rect.width + (upper.rect.width - lower.rect.width) * t,
            height: lower.rect.height + (upper.rect.height - lower.rect.height) * t
        )
    }

    func confidence(at time: TimeInterval) -> Double {
        guard !samples.isEmpty else { return 0 }
        let nearest = samples.min { abs($0.time - time) < abs($1.time - time) }
        return nearest?.confidence ?? 0
    }
}

/// An adjustment restricted to a mask — the "brighten just the face" case.
struct SelectiveAdjustment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var mask: MaskDefinition
    var adjustments: AdjustmentSet
    var timeRange: TimeRange?

    init(
        id: UUID = UUID(),
        mask: MaskDefinition = MaskDefinition(),
        adjustments: AdjustmentSet = AdjustmentSet(),
        timeRange: TimeRange? = nil
    ) {
        self.id = id
        self.mask = mask
        self.adjustments = adjustments
        self.timeRange = timeRange
    }

    var isActive: Bool { !adjustments.isIdentity }
}
