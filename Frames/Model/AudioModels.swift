import Foundation

/// Where a piece of audio came from. This decides how it is drawn on the
/// timeline and which one automatic ducking lowers.
enum AudioRole: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// The audio that came with a video clip. Not a separate clip — it is
    /// controlled through the video clip's own volume.
    case sourceAudio
    case music
    case voiceover
    case extracted
    case soundEffect

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sourceAudio: String(localized: "Original Audio", comment: "Audio role")
        case .music: String(localized: "Music", comment: "Audio role")
        case .voiceover: String(localized: "Voiceover", comment: "Audio role")
        case .extracted: String(localized: "Extracted Audio", comment: "Audio role")
        case .soundEffect: String(localized: "Sound", comment: "Audio role")
        }
    }

    var symbolName: String {
        switch self {
        case .sourceAudio: "waveform"
        case .music: "music.note"
        case .voiceover: "mic.fill"
        case .extracted: "waveform.badge.plus"
        case .soundEffect: "speaker.wave.2.fill"
        }
    }

    /// Roles that duck the music bed when `AudioMixSettings.autoDuck` is on.
    var isSpokenContent: Bool {
        self == .voiceover
    }

    /// Roles that get ducked.
    var isDuckable: Bool {
        self == .music
    }
}

/// An audio clip placed on the timeline.
struct AudioClip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var assetID: UUID
    var role: AudioRole
    /// Which part of the source file plays.
    var source: TimeRange
    /// Where it starts on the timeline.
    var timelineStart: TimeInterval
    /// 0...2, where 1 is unity gain.
    var volume: Double
    var isMuted: Bool
    var fadeIn: TimeInterval
    var fadeOut: TimeInterval
    var speed: Double
    var keyframes: KeyframeSet
    /// A short label shown on the clip, e.g. the file name or "Voiceover 1".
    var label: String

    init(
        id: UUID = UUID(),
        assetID: UUID,
        role: AudioRole = .music,
        source: TimeRange,
        timelineStart: TimeInterval = 0,
        volume: Double = 1,
        isMuted: Bool = false,
        fadeIn: TimeInterval = 0,
        fadeOut: TimeInterval = 0,
        speed: Double = 1,
        keyframes: KeyframeSet = KeyframeSet(),
        label: String = ""
    ) {
        self.id = id
        self.assetID = assetID
        self.role = role
        self.source = source
        self.timelineStart = max(0, timelineStart)
        self.volume = min(max(volume, 0), 2)
        self.isMuted = isMuted
        self.fadeIn = max(0, fadeIn)
        self.fadeOut = max(0, fadeOut)
        self.speed = min(max(speed, 0.25), 4)
        self.keyframes = keyframes
        self.label = label
    }

    /// Duration on the timeline, after speed.
    var timelineDuration: TimeInterval {
        source.duration / max(speed, 0.01)
    }

    var timelineRange: TimeRange {
        TimeRange(start: timelineStart, duration: timelineDuration)
    }

    /// Effective gain at a moment, including fades, keyframes and mute.
    func gain(at timelineTime: TimeInterval) -> Double {
        guard !isMuted else { return 0 }
        let range = timelineRange
        guard range.contains(timelineTime) || abs(timelineTime - range.end) < 0.0001 else { return 0 }

        var gain = keyframes.value(.volume, at: timelineTime, fallback: volume)

        if fadeIn > 0 {
            let elapsed = timelineTime - range.start
            if elapsed < fadeIn {
                gain *= min(max(elapsed / fadeIn, 0), 1)
            }
        }
        if fadeOut > 0 {
            let remaining = range.end - timelineTime
            if remaining < fadeOut {
                gain *= min(max(remaining / fadeOut, 0), 1)
            }
        }
        return min(max(gain, 0), 2)
    }

    mutating func normalize(maximumSourceDuration: TimeInterval) {
        source.start = max(0, source.start)
        let available = max(0, maximumSourceDuration - source.start)
        source.duration = min(max(source.duration, 0.05), max(available, 0.05))
        let half = timelineDuration / 2
        fadeIn = min(fadeIn, half)
        fadeOut = min(fadeOut, half)
    }
}

/// Project-wide audio behaviour.
struct AudioMixSettings: Codable, Hashable, Sendable {
    /// Lowers music while a voiceover is playing. Implemented as volume
    /// automation over the music clips, so the user can see it, change it and
    /// undo it — the source audio is never rewritten.
    var autoDuck: Bool
    /// How far music drops, 0...1, where 1 is silence.
    var duckAmount: Double
    /// Ramp in and out of a duck.
    var duckRamp: TimeInterval
    /// Master output gain.
    var masterVolume: Double

    init(
        autoDuck: Bool = false,
        duckAmount: Double = 0.7,
        duckRamp: TimeInterval = 0.35,
        masterVolume: Double = 1
    ) {
        self.autoDuck = autoDuck
        self.duckAmount = min(max(duckAmount, 0), 1)
        self.duckRamp = max(0, duckRamp)
        self.masterVolume = min(max(masterVolume, 0), 2)
    }

    static let `default` = AudioMixSettings()
}
