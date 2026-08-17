import CoreGraphics
import Foundation

/// The two kinds of media Frames edits. The chooser detects this from the
/// asset; the user is never asked which kind of edit they want to start.
enum MediaKind: String, Codable, Hashable, Sendable, CaseIterable {
    case photo
    case video
}

/// An immutable reference to media that has been copied into the session's
/// working directory.
///
/// Source files are never written to. Everything the user does is recorded as
/// data in `EditDocument` and applied at render time.
struct SourceAsset: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// File name relative to the session's `Media` directory.
    var fileName: String
    var kind: MediaKind
    /// Duration in seconds of the underlying file. Zero for stills.
    var duration: TimeInterval
    /// Presentation size in pixels, with the asset's preferred transform
    /// already applied — i.e. what the user sees, not what is stored.
    var displaySize: CGSize
    /// Nominal frame rate. Zero for stills.
    var nominalFrameRate: Double
    var hasAudioTrack: Bool
    var importedAt: Date

    init(
        id: UUID = UUID(),
        fileName: String,
        kind: MediaKind,
        duration: TimeInterval = 0,
        displaySize: CGSize = .zero,
        nominalFrameRate: Double = 0,
        hasAudioTrack: Bool = false,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.duration = max(0, duration)
        self.displaySize = displaySize
        self.nominalFrameRate = max(0, nominalFrameRate)
        self.hasAudioTrack = hasAudioTrack
        self.importedAt = importedAt
    }

    var aspectRatio: CGFloat {
        guard displaySize.width > 0, displaySize.height > 0 else { return 1 }
        return displaySize.width / displaySize.height
    }

    var isPortrait: Bool { aspectRatio < 1 }
}

/// A half-open range on a timeline, in seconds.
///
/// Frames keeps time as `TimeInterval` in the model and converts to `CMTime`
/// only at the composition boundary, with a single fixed timescale. Keeping the
/// model in seconds makes the editing math testable without CoreMedia and keeps
/// the session file readable.
struct TimeRange: Codable, Hashable, Sendable {
    var start: TimeInterval
    var duration: TimeInterval

    init(start: TimeInterval, duration: TimeInterval) {
        self.start = start
        self.duration = max(0, duration)
    }

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.duration = max(0, end - start)
    }

    static let zero = TimeRange(start: 0, duration: 0)

    var end: TimeInterval { start + duration }
    var isEmpty: Bool { duration <= 0 }

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    func intersects(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    func intersection(_ other: TimeRange) -> TimeRange? {
        let lower = Swift.max(start, other.start)
        let upper = Swift.min(end, other.end)
        guard upper > lower else { return nil }
        return TimeRange(start: lower, end: upper)
    }

    func clamped(to bounds: TimeRange) -> TimeRange {
        intersection(bounds) ?? TimeRange(start: Swift.min(Swift.max(start, bounds.start), bounds.end), duration: 0)
    }

    func offset(by delta: TimeInterval) -> TimeRange {
        TimeRange(start: start + delta, duration: duration)
    }
}

extension TimeInterval {
    /// `1:04.2` style, used everywhere a duration or playhead position is shown.
    var framesTimecode: String {
        let total = Swift.max(0, self)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        let tenths = Int((total - floor(total)) * 10)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d.%d", minutes, seconds, tenths)
    }

    /// `1:04` style, for compact places like clip labels.
    var framesShortTimecode: String {
        let total = Swift.max(0, self)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
