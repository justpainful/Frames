import Foundation
import OSLog

/// Central logging identifiers.
///
/// Every expensive subsystem (render, timeline, vision, export) logs through a
/// category here so Instruments and `log stream` can be filtered without
/// guessing at subsystem strings.
enum FramesLog {
    static let subsystem = "com.frames.Frames"

    static let importer = Logger(subsystem: subsystem, category: "import")
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let timeline = Logger(subsystem: subsystem, category: "timeline")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let vision = Logger(subsystem: subsystem, category: "vision")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")

    /// Signposter used to bracket expensive work so Instruments shows it as
    /// intervals rather than a wall of point events.
    static let signposter = OSSignposter(subsystem: subsystem, category: "performance")
}
