import CoreGraphics
import Foundation

/// The colour treatment applied to the whole composition.
///
/// Kept at document level rather than per-clip because that is how the tool
/// behaves: "Adjust" and "Filters" grade the edit, not one segment of it. Per
/// clip variation is expressed through the clip's own properties.
struct Grade: Codable, Hashable, Sendable {
    var adjustments: AdjustmentSet
    var filter: FilterInstance?

    init(adjustments: AdjustmentSet = AdjustmentSet(), filter: FilterInstance? = nil) {
        self.adjustments = adjustments
        self.filter = filter
    }

    static let identity = Grade()

    var isIdentity: Bool {
        adjustments.isIdentity && (filter == nil || filter?.intensity == 0)
    }
}

/// A still being edited.
struct PhotoContent: Codable, Hashable, Sendable {
    var assetID: UUID
    var crop: CropState
    var transform: LayerTransform

    init(assetID: UUID, crop: CropState = .identity, transform: LayerTransform = .identity) {
        self.assetID = assetID
        self.crop = crop
        self.transform = transform
    }
}

/// Optional guides drawn over the canvas for vertical layouts.
struct SafeAreaGuides: Codable, Hashable, Sendable {
    var isEnabled: Bool
    /// Fraction of the height reserved at the top for system chrome.
    var topInset: Double
    /// Fraction reserved at the bottom for captions and controls.
    var bottomInset: Double
    /// Fraction reserved on the trailing edge.
    var trailingInset: Double

    init(
        isEnabled: Bool = false,
        topInset: Double = 0.12,
        bottomInset: Double = 0.22,
        trailingInset: Double = 0.16
    ) {
        self.isEnabled = isEnabled
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.trailingInset = trailingInset
    }

    static let `default` = SafeAreaGuides()
}

/// The complete, self-contained description of an edit.
///
/// This is the single source of truth. The preview renderer and the export
/// renderer both consume exactly this value, which is what guarantees that what
/// the user sees is what they get. Nothing visible in the editor is allowed to
/// live outside it.
struct EditDocument: Identifiable, Codable, Hashable, Sendable {
    /// Bumped whenever the shape of the document changes incompatibly. A
    /// recovered session with a different version is discarded rather than
    /// half-decoded.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var kind: MediaKind
    var assets: [SourceAsset]

    /// Video edits. Empty for photos.
    var videoTrack: [VideoClip]
    /// Photo edits. `nil` for videos.
    var photo: PhotoContent?

    var audioClips: [AudioClip]
    var textOverlays: [TextOverlay]
    var imageOverlays: [ImageOverlay]
    var drawings: [DrawingOverlay]
    var blurRegions: [BlurRegion]
    var selectiveAdjustments: [SelectiveAdjustment]
    var effects: [EffectInstance]
    var trackedObjects: [TrackedObject]

    var grade: Grade
    var portrait: PortraitSettings
    var background: BackgroundStyle
    var outputAspect: AspectPreset
    var audioMix: AudioMixSettings
    var safeAreaGuides: SafeAreaGuides

    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        kind: MediaKind,
        assets: [SourceAsset] = [],
        videoTrack: [VideoClip] = [],
        photo: PhotoContent? = nil,
        audioClips: [AudioClip] = [],
        textOverlays: [TextOverlay] = [],
        imageOverlays: [ImageOverlay] = [],
        drawings: [DrawingOverlay] = [],
        blurRegions: [BlurRegion] = [],
        selectiveAdjustments: [SelectiveAdjustment] = [],
        effects: [EffectInstance] = [],
        trackedObjects: [TrackedObject] = [],
        grade: Grade = .identity,
        portrait: PortraitSettings = .off,
        background: BackgroundStyle = .default,
        outputAspect: AspectPreset = .original,
        audioMix: AudioMixSettings = .default,
        safeAreaGuides: SafeAreaGuides = .default,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.schemaVersion = EditDocument.currentSchemaVersion
        self.id = id
        self.kind = kind
        self.assets = assets
        self.videoTrack = videoTrack
        self.photo = photo
        self.audioClips = audioClips
        self.textOverlays = textOverlays
        self.imageOverlays = imageOverlays
        self.drawings = drawings
        self.blurRegions = blurRegions
        self.selectiveAdjustments = selectiveAdjustments
        self.effects = effects
        self.trackedObjects = trackedObjects
        self.grade = grade
        self.portrait = portrait
        self.background = background
        self.outputAspect = outputAspect
        self.audioMix = audioMix
        self.safeAreaGuides = safeAreaGuides
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    // MARK: - Construction

    static func photo(asset: SourceAsset) -> EditDocument {
        EditDocument(
            kind: .photo,
            assets: [asset],
            photo: PhotoContent(assetID: asset.id)
        )
    }

    static func video(asset: SourceAsset) -> EditDocument {
        EditDocument(
            kind: .video,
            assets: [asset],
            videoTrack: [
                VideoClip(assetID: asset.id, source: TimeRange(start: 0, duration: asset.duration))
            ]
        )
    }

    // MARK: - Assets

    func asset(id: UUID) -> SourceAsset? {
        assets.first { $0.id == id }
    }

    /// The asset the edit is fundamentally about — the imported photo, or the
    /// first video clip's asset.
    var primaryAsset: SourceAsset? {
        if let photo { return asset(id: photo.assetID) }
        if let first = videoTrack.first { return asset(id: first.assetID) }
        return assets.first
    }

    mutating func addAsset(_ asset: SourceAsset) {
        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[index] = asset
        } else {
            assets.append(asset)
        }
    }

    /// Assets no longer referenced by anything. Used to clean the session's
    /// media directory after undo removes the layer that needed them.
    func unreferencedAssetIDs() -> [UUID] {
        var referenced = Set<UUID>()
        if let photo { referenced.insert(photo.assetID) }
        videoTrack.forEach { referenced.insert($0.assetID) }
        audioClips.forEach { referenced.insert($0.assetID) }
        imageOverlays.forEach { referenced.insert($0.assetID) }
        if let backgroundImage = background.imageAssetID { referenced.insert(backgroundImage) }
        return assets.map(\.id).filter { !referenced.contains($0) }
    }

    // MARK: - Timing

    /// Total duration of the composition. Photos have a nominal duration so the
    /// same renderer can produce a still or a frame of video.
    var duration: TimeInterval {
        switch kind {
        case .photo:
            return 0
        case .video:
            let videoDuration = videoTrack.reduce(0) { $0 + $1.timelineDuration }
            let audioEnd = audioClips.map(\.timelineRange.end).max() ?? 0
            return max(videoDuration, audioEnd)
        }
    }

    /// Duration of the video track alone, ignoring audio that runs past it.
    var videoDuration: TimeInterval {
        videoTrack.reduce(0) { $0 + $1.timelineDuration }
    }

    /// Start time of each clip on the timeline, in order.
    var clipStartTimes: [TimeInterval] {
        var times: [TimeInterval] = []
        var cursor: TimeInterval = 0
        for clip in videoTrack {
            times.append(cursor)
            cursor += clip.timelineDuration
        }
        return times
    }

    func startTime(ofClip clipID: UUID) -> TimeInterval? {
        var cursor: TimeInterval = 0
        for clip in videoTrack {
            if clip.id == clipID { return cursor }
            cursor += clip.timelineDuration
        }
        return nil
    }

    func timelineRange(ofClip clipID: UUID) -> TimeRange? {
        guard let start = startTime(ofClip: clipID),
              let clip = videoTrack.first(where: { $0.id == clipID })
        else { return nil }
        return TimeRange(start: start, duration: clip.timelineDuration)
    }

    /// The clip playing at a timeline position, and how far into it we are.
    func clip(at time: TimeInterval) -> (clip: VideoClip, offset: TimeInterval, index: Int)? {
        var cursor: TimeInterval = 0
        for (index, clip) in videoTrack.enumerated() {
            let next = cursor + clip.timelineDuration
            if time < next || index == videoTrack.count - 1 {
                return (clip, min(max(time - cursor, 0), clip.timelineDuration), index)
            }
            cursor = next
        }
        return nil
    }

    /// Every boundary a scrub or trim should snap to: clip edges, keyframes and
    /// audio clip edges.
    var snapPoints: [TimeInterval] {
        var points: Set<Int> = [0]
        var cursor: TimeInterval = 0
        for clip in videoTrack {
            points.insert(Int((cursor * 1000).rounded()))
            cursor += clip.timelineDuration
            points.insert(Int((cursor * 1000).rounded()))
            for time in clip.keyframes.allTimes {
                points.insert(Int(((cursor + time) * 1000).rounded()))
            }
        }
        for audio in audioClips {
            points.insert(Int((audio.timelineRange.start * 1000).rounded()))
            points.insert(Int((audio.timelineRange.end * 1000).rounded()))
        }
        for text in textOverlays {
            if let range = text.timeRange {
                points.insert(Int((range.start * 1000).rounded()))
                points.insert(Int((range.end * 1000).rounded()))
            }
        }
        return points.sorted().map { TimeInterval($0) / 1000 }
    }

    // MARK: - Geometry

    /// Aspect ratio of the source content, before the output aspect is applied.
    var sourceAspectRatio: CGFloat {
        if let photo, let asset = asset(id: photo.assetID) {
            return photo.crop.outputAspectRatio(sourceAspectRatio: asset.aspectRatio)
        }
        if let first = videoTrack.first, let asset = asset(id: first.assetID) {
            return first.outputAspectRatio(sourceAspectRatio: asset.aspectRatio)
        }
        return primaryAsset?.aspectRatio ?? 1
    }

    /// The aspect ratio the composition renders at.
    var outputAspectRatio: CGFloat {
        outputAspect.ratio ?? sourceAspectRatio
    }

    /// Pixel size the composition renders at, given a target for the long edge.
    func renderSize(longEdge: CGFloat) -> CGSize {
        let ratio = outputAspectRatio
        if ratio >= 1 {
            let width = longEdge
            return CGSize(width: width, height: (width / ratio).rounded())
        }
        let height = longEdge
        return CGSize(width: (height * ratio).rounded(), height: height)
    }

    // MARK: - State

    /// True when nothing has been changed since import. Drives whether closing
    /// the editor needs a confirmation.
    var isPristine: Bool {
        !portrait.isEnabled
            && grade.isIdentity
            && textOverlays.isEmpty
            && imageOverlays.isEmpty
            && drawings.isEmpty
            && blurRegions.isEmpty
            && selectiveAdjustments.isEmpty
            && effects.isEmpty
            && audioClips.isEmpty
            && background == .default
            && outputAspect == .original
            && (photo?.crop.isIdentity ?? true)
            && (photo?.transform.isIdentity ?? true)
            && videoTrackIsPristine
    }

    private var videoTrackIsPristine: Bool {
        guard videoTrack.count <= 1 else { return false }
        guard let clip = videoTrack.first, let asset = asset(id: clip.assetID) else { return true }
        return clip.source.start == 0
            && abs(clip.source.duration - asset.duration) < 0.01
            && clip.speed == 1
            && !clip.isReversed
            && clip.volume == 1
            && !clip.isMuted
            && clip.crop.isIdentity
            && clip.transform.isIdentity
            && !clip.isFrozen
    }

    /// A short human description of the edit, used in the recovery prompt.
    var summary: String {
        switch kind {
        case .photo:
            return String(localized: "Photo edit", comment: "Recovery summary")
        case .video:
            return String(
                localized: "Video edit · \(duration.framesShortTimecode)",
                comment: "Recovery summary with duration"
            )
        }
    }

    mutating func touch() {
        modifiedAt = Date()
    }
}
