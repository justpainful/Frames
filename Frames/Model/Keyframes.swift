import CoreGraphics
import Foundation

/// A property that can be animated over time.
///
/// Keyframes are deliberately an *advanced* feature in Frames: direct
/// manipulation sets the value, and a keyframe is only created when the user
/// taps the diamond. Nothing in the normal workflow requires understanding
/// them, and any layer with no keyframes evaluates to its static value for
/// free.
enum KeyframeProperty: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case positionX
    case positionY
    case scale
    case rotation
    case opacity
    case blurStrength
    case volume
    case effectIntensity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .positionX: String(localized: "Horizontal Position", comment: "Keyframe property")
        case .positionY: String(localized: "Vertical Position", comment: "Keyframe property")
        case .scale: String(localized: "Scale", comment: "Keyframe property")
        case .rotation: String(localized: "Rotation", comment: "Keyframe property")
        case .opacity: String(localized: "Opacity", comment: "Keyframe property")
        case .blurStrength: String(localized: "Blur", comment: "Keyframe property")
        case .volume: String(localized: "Volume", comment: "Keyframe property")
        case .effectIntensity: String(localized: "Intensity", comment: "Keyframe property")
        }
    }
}

enum KeyframeEasing: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case hold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: String(localized: "Linear", comment: "Keyframe easing")
        case .easeIn: String(localized: "Ease In", comment: "Keyframe easing")
        case .easeOut: String(localized: "Ease Out", comment: "Keyframe easing")
        case .easeInOut: String(localized: "Ease In Out", comment: "Keyframe easing")
        case .hold: String(localized: "Hold", comment: "Keyframe easing")
        }
    }

    /// Maps a normalized 0...1 progress onto an eased 0...1 progress.
    func apply(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear: return x
        case .easeIn: return x * x
        case .easeOut: return 1 - (1 - x) * (1 - x)
        case .easeInOut: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        case .hold: return 0
        }
    }
}

struct Keyframe: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Time on the timeline, in seconds.
    var time: TimeInterval
    var value: Double
    /// Easing applied on the way *out* of this keyframe.
    var easing: KeyframeEasing

    init(id: UUID = UUID(), time: TimeInterval, value: Double, easing: KeyframeEasing = .easeInOut) {
        self.id = id
        self.time = time
        self.value = value
        self.easing = easing
    }
}

/// The keyframes for one property, kept sorted by time.
struct KeyframeTrack: Codable, Hashable, Sendable {
    var property: KeyframeProperty
    private(set) var keyframes: [Keyframe]

    init(property: KeyframeProperty, keyframes: [Keyframe] = []) {
        self.property = property
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    var isEmpty: Bool { keyframes.isEmpty }

    mutating func set(_ value: Double, at time: TimeInterval, easing: KeyframeEasing = .easeInOut) {
        if let index = keyframes.firstIndex(where: { abs($0.time - time) < 0.001 }) {
            keyframes[index].value = value
            keyframes[index].easing = easing
        } else {
            keyframes.append(Keyframe(time: time, value: value, easing: easing))
            keyframes.sort { $0.time < $1.time }
        }
    }

    mutating func removeKeyframe(at time: TimeInterval) {
        keyframes.removeAll { abs($0.time - time) < 0.001 }
    }

    mutating func removeKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
    }

    func keyframe(at time: TimeInterval) -> Keyframe? {
        keyframes.first { abs($0.time - time) < 0.001 }
    }

    /// Value at `time`, holding the first and last values outside the track's
    /// own range so a partially-keyframed property never snaps to zero.
    func value(at time: TimeInterval, fallback: Double) -> Double {
        guard let first = keyframes.first else { return fallback }
        guard let last = keyframes.last else { return fallback }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }

        var lower = first
        var upper = last
        for keyframe in keyframes {
            if keyframe.time <= time { lower = keyframe }
            if keyframe.time >= time { upper = keyframe; break }
        }
        let span = upper.time - lower.time
        guard span > 0 else { return upper.value }
        let progress = lower.easing.apply((time - lower.time) / span)
        return lower.value + (upper.value - lower.value) * progress
    }
}

/// The full set of keyframe tracks attached to one layer.
struct KeyframeSet: Codable, Hashable, Sendable {
    private var tracks: [String: KeyframeTrack]

    init() {
        tracks = [:]
    }

    var isEmpty: Bool { tracks.values.allSatisfy(\.isEmpty) }

    var animatedProperties: [KeyframeProperty] {
        KeyframeProperty.allCases.filter { !(tracks[$0.rawValue]?.isEmpty ?? true) }
    }

    func track(_ property: KeyframeProperty) -> KeyframeTrack? {
        guard let track = tracks[property.rawValue], !track.isEmpty else { return nil }
        return track
    }

    func isAnimated(_ property: KeyframeProperty) -> Bool {
        track(property) != nil
    }

    func value(_ property: KeyframeProperty, at time: TimeInterval, fallback: Double) -> Double {
        track(property)?.value(at: time, fallback: fallback) ?? fallback
    }

    func hasKeyframe(_ property: KeyframeProperty, at time: TimeInterval) -> Bool {
        track(property)?.keyframe(at: time) != nil
    }

    mutating func setKeyframe(
        _ property: KeyframeProperty,
        value: Double,
        at time: TimeInterval,
        easing: KeyframeEasing = .easeInOut
    ) {
        var track = tracks[property.rawValue] ?? KeyframeTrack(property: property)
        track.set(value, at: time, easing: easing)
        tracks[property.rawValue] = track
    }

    mutating func removeKeyframe(_ property: KeyframeProperty, at time: TimeInterval) {
        guard var track = tracks[property.rawValue] else { return }
        track.removeKeyframe(at: time)
        if track.isEmpty {
            tracks.removeValue(forKey: property.rawValue)
        } else {
            tracks[property.rawValue] = track
        }
    }

    mutating func removeAll(_ property: KeyframeProperty) {
        tracks.removeValue(forKey: property.rawValue)
    }

    mutating func removeAll() {
        tracks.removeAll()
    }

    /// Every distinct keyframe time across all tracks, for drawing diamonds on
    /// the timeline.
    var allTimes: [TimeInterval] {
        var times: Set<Int> = []
        for track in tracks.values {
            for keyframe in track.keyframes {
                times.insert(Int((keyframe.time * 1000).rounded()))
            }
        }
        return times.sorted().map { TimeInterval($0) / 1000 }
    }

    /// Shifts every keyframe, used when a clip moves on the timeline.
    mutating func shift(by delta: TimeInterval) {
        guard delta != 0 else { return }
        for (key, track) in tracks {
            let shifted = track.keyframes.map {
                Keyframe(id: $0.id, time: $0.time + delta, value: $0.value, easing: $0.easing)
            }
            tracks[key] = KeyframeTrack(property: track.property, keyframes: shifted)
        }
    }
}

/// Applies a keyframe set to a static transform, producing the transform for a
/// specific moment. Layers that are not animated return the input untouched, so
/// this is safe to call on every rendered frame.
extension LayerTransform {
    func evaluated(with keyframes: KeyframeSet, at time: TimeInterval) -> LayerTransform {
        guard !keyframes.isEmpty else { return self }
        var result = self
        result.position.x = keyframes.value(.positionX, at: time, fallback: position.x)
        result.position.y = keyframes.value(.positionY, at: time, fallback: position.y)
        result.scale = keyframes.value(.scale, at: time, fallback: scale)
        result.rotation = keyframes.value(.rotation, at: time, fallback: rotation)
        result.opacity = keyframes.value(.opacity, at: time, fallback: opacity)
        return result
    }
}
