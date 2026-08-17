import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A file received from the photo picker or the file importer, already staged
/// into the session's media directory.
///
/// Videos are never loaded into memory to import them — the transfer hands us a
/// file, and we move it. Only the container is copied; the media itself is
/// never re-encoded.
struct ImportedFile: Transferable, Sendable {
    /// Location inside the session media directory.
    let url: URL
    let kind: MediaKind

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let staged = try MediaStaging.stage(received.file, kind: .video)
            return ImportedFile(url: staged, kind: .video)
        }
        FileRepresentation(importedContentType: .image) { received in
            let staged = try MediaStaging.stage(received.file, kind: .photo)
            return ImportedFile(url: staged, kind: .photo)
        }
    }
}

/// Copies incoming files into the session directory under a stable name.
enum MediaStaging {
    /// Extensions we fall back to when the source has none.
    static func defaultExtension(for kind: MediaKind) -> String {
        kind == .video ? "mov" : "jpg"
    }

    static func stage(_ source: URL, kind: MediaKind) throws -> URL {
        try SessionPaths.createDirectories()
        var fileExtension = source.pathExtension.lowercased()
        if fileExtension.isEmpty { fileExtension = defaultExtension(for: kind) }
        let fileName = "\(UUID().uuidString).\(fileExtension)"
        let destination = SessionPaths.mediaURL(for: fileName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Stages a file the user picked through the file importer, which arrives
    /// as a security-scoped URL rather than a copy we own.
    static func stageSecurityScoped(_ source: URL, kind: MediaKind) throws -> URL {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        return try stage(source, kind: kind)
    }
}
