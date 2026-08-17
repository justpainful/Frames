import Foundation

/// Where Frames puts things on disk.
///
/// There is exactly one live session directory. Media the user imports is
/// copied into it so the edit survives the original being deleted from the
/// library, and everything else — thumbnails, waveforms, render scratch — lives
/// in caches the system is free to reclaim.
enum SessionPaths {
    private static let folderName = "Frames"

    /// Survives across launches. Holds the one recoverable session.
    static var sessionRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("Session", isDirectory: true)
    }

    static var documentFile: URL {
        sessionRoot.appendingPathComponent("document.json", isDirectory: false)
    }

    /// Imported source media for the current session.
    static var mediaDirectory: URL {
        sessionRoot.appendingPathComponent("Media", isDirectory: true)
    }

    /// Cached background cut-outs produced by Vision.
    static var cutoutDirectory: URL {
        sessionRoot.appendingPathComponent("Cutouts", isDirectory: true)
    }

    /// Reclaimable: timeline thumbnails and audio waveforms.
    static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static var thumbnailCache: URL {
        cacheRoot.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    static var waveformCache: URL {
        cacheRoot.appendingPathComponent("Waveforms", isDirectory: true)
    }

    /// Scratch space for renders in flight. Emptied on launch and after every
    /// completed export.
    static var exportScratch: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("Export", isDirectory: true)
    }

    static func mediaURL(for fileName: String) -> URL {
        mediaDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func cutoutURL(for fileName: String) -> URL {
        cutoutDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Creates every directory the app writes to. Safe to call repeatedly.
    static func createDirectories() throws {
        let manager = FileManager.default
        for url in [sessionRoot, mediaDirectory, cutoutDirectory, thumbnailCache, waveformCache, exportScratch] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var session = sessionRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? session.setResourceValues(values)
    }

    /// Deletes the recoverable session and everything it owns.
    static func clearSession() {
        try? FileManager.default.removeItem(at: sessionRoot)
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cutoutDirectory, withIntermediateDirectories: true)
    }

    /// Removes scratch that no longer belongs to anything. Called at launch and
    /// after each export so the app never accumulates invisible gigabytes.
    static func pruneScratch() {
        let manager = FileManager.default
        if let contents = try? manager.contentsOfDirectory(at: exportScratch, includingPropertiesForKeys: nil) {
            for url in contents { try? manager.removeItem(at: url) }
        }
    }

    /// Removes cached derivatives older than the given age.
    static func pruneCaches(olderThan age: TimeInterval = 60 * 60 * 24 * 7) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        for directory in [thumbnailCache, waveformCache] {
            guard let contents = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for url in contents {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified < cutoff {
                    try? manager.removeItem(at: url)
                }
            }
        }
    }

    /// Free space on the volume Frames writes to, in bytes.
    static func availableCapacity() -> Int64? {
        let values = try? sessionRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
