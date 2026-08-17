import CoreGraphics
import Foundation

/// Maps between timeline seconds and screen points.
///
/// Zoom is stored as points-per-second so the conversion is a multiply in both
/// directions, and so a pinch can hold a fixed point on screen simply by
/// solving for the scroll offset that keeps it there.
struct TimelineScale: Equatable, Sendable {
    /// Screen points for one second of timeline.
    var pointsPerSecond: CGFloat

    /// Roughly a whole minute across an iPhone.
    static let minimumPointsPerSecond: CGFloat = 6
    /// Roughly a third of a second across an iPhone, which is frame-level.
    static let maximumPointsPerSecond: CGFloat = 900

    static let `default` = TimelineScale(pointsPerSecond: 60)

    init(pointsPerSecond: CGFloat) {
        self.pointsPerSecond = min(
            max(pointsPerSecond, Self.minimumPointsPerSecond),
            Self.maximumPointsPerSecond
        )
    }

    /// A scale that fits `duration` into `width`, which is what the timeline
    /// opens at.
    static func fitting(duration: TimeInterval, in width: CGFloat) -> TimelineScale {
        guard duration > 0, width > 0 else { return .default }
        return TimelineScale(pointsPerSecond: width / CGFloat(duration))
    }

    func point(for time: TimeInterval) -> CGFloat {
        CGFloat(time) * pointsPerSecond
    }

    func time(for point: CGFloat) -> TimeInterval {
        TimeInterval(point / max(pointsPerSecond, 0.001))
    }

    func width(for duration: TimeInterval) -> CGFloat {
        CGFloat(max(duration, 0)) * pointsPerSecond
    }

    func scaled(by factor: CGFloat) -> TimelineScale {
        TimelineScale(pointsPerSecond: pointsPerSecond * factor)
    }

    var isAtMinimum: Bool { pointsPerSecond <= Self.minimumPointsPerSecond + 0.01 }
    var isAtMaximum: Bool { pointsPerSecond >= Self.maximumPointsPerSecond - 0.01 }

    /// How far a drag can be from a snap point and still snap, in seconds.
    /// Constant in *points*, so snapping feels the same at every zoom.
    var snapTolerance: TimeInterval {
        time(for: 12)
    }

    /// Spacing between ruler ticks, chosen so labels never collide.
    var tickInterval: TimeInterval {
        let candidates: [TimeInterval] = [
            1.0 / 30, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600
        ]
        let minimumSpacing: CGFloat = 56
        return candidates.first { width(for: $0) >= minimumSpacing } ?? 600
    }

    /// How many thumbnails a clip of this width should show.
    func thumbnailCount(forWidth width: CGFloat, thumbnailWidth: CGFloat) -> Int {
        guard thumbnailWidth > 0 else { return 1 }
        return max(1, min(Int(ceil(width / thumbnailWidth)), 60))
    }
}
