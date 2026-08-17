import Foundation
import OSLog

/// Persists the one in-flight edit so an interruption doesn't lose work.
///
/// This is crash recovery, not a project system. Exactly one document is ever
/// on disk; exporting or explicitly discarding removes it. The user is never
/// shown a list, never names anything, and never manages storage.
actor SessionRecoveryStore {
    private let logger = FramesLog.persistence
    private let encoder = FramesJSON.encoder
    private let decoder = FramesJSON.decoder

    /// Writes atomically so a kill mid-write cannot leave a truncated file that
    /// the next launch would fail to parse.
    func save(_ document: EditDocument) throws {
        try SessionPaths.createDirectories()
        let data = try encoder.encode(document)
        let target = SessionPaths.documentFile
        let temporary = target.appendingPathExtension("writing")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        logger.debug("Saved recoverable session (\(data.count, privacy: .public) bytes)")
    }

    /// Returns the stored document, or `nil` when there is nothing to recover.
    ///
    /// A document written by an incompatible build, or one whose media has gone
    /// missing, is discarded rather than partially restored — a half-recovered
    /// edit is worse than a clean start.
    func load() -> EditDocument? {
        let url = SessionPaths.documentFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let document = try decoder.decode(EditDocument.self, from: data)
            guard document.schemaVersion == EditDocument.currentSchemaVersion else {
                logger.notice("Discarding session written by an incompatible schema version")
                discard()
                return nil
            }
            guard mediaIsIntact(for: document) else {
                logger.notice("Discarding session whose media is missing")
                discard()
                return nil
            }
            return document
        } catch {
            logger.error("Failed to read recoverable session: \(error.localizedDescription, privacy: .public)")
            discard()
            return nil
        }
    }

    /// A cheap check for "is there something to offer the user", without
    /// decoding the whole document body.
    func summary() -> RecoverableSessionSummary? {
        guard let document = load() else { return nil }
        guard !document.isPristine else {
            // Nothing was actually changed: there is no work to recover, so
            // don't interrupt the user with a prompt about it.
            discard()
            return nil
        }
        return RecoverableSessionSummary(
            id: document.id,
            kind: document.kind,
            modifiedAt: document.modifiedAt
        )
    }

    func discard() {
        SessionPaths.clearSession()
        logger.debug("Discarded recoverable session")
    }

    private func mediaIsIntact(for document: EditDocument) -> Bool {
        let manager = FileManager.default
        for asset in document.assets {
            let url = SessionPaths.mediaURL(for: asset.fileName)
            if !manager.fileExists(atPath: url.path) { return false }
        }
        return !document.assets.isEmpty
    }
}
