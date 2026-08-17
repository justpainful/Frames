import AVFoundation
import CoreMedia
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Brings audio into a session, from a file or out of another video.
struct AudioImportService: Sendable {
    private var logger: Logger { FramesLog.audio }

    func importAudio(fromFileAt url: URL) async throws -> SourceAsset {
        let staged = try MediaStaging.stageSecurityScoped(url, kind: .video)
        return try await describe(staged)
    }

    /// Pulls the audio track out of a video and writes it as an audio-only file.
    ///
    /// The video is never re-encoded: only the audio track is passed through,
    /// so extracting a soundtrack from a 4K clip costs about as much as copying
    /// the audio.
    func extractAudio(from asset: SourceAsset) async throws -> SourceAsset {
        let signpost = FramesLog.signposter.beginInterval("extractAudio")
        defer { FramesLog.signposter.endInterval("extractAudio", signpost) }

        let sourceURL = SessionPaths.mediaURL(for: asset.fileName)
        let source = AVURLAsset(url: sourceURL)
        guard let audioTrack = try await source.loadTracks(withMediaType: .audio).first else {
            throw FramesError.unsupportedMedia("that video has no audio track")
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw FramesError.exportFailed("could not create an audio track")
        }
        let duration = try await source.load(.duration)
        try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: audioTrack,
            at: .zero
        )

        try SessionPaths.createDirectories()
        let fileName = "\(UUID().uuidString).m4a"
        let destination = SessionPaths.mediaURL(for: fileName)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw FramesError.exportFailed("no audio export session")
        }

        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            logger.error("Audio extraction failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.exportFailed(error.localizedDescription)
        }

        return try await describe(destination)
    }

    private func describe(_ url: URL) async throws -> SourceAsset {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else {
            throw FramesError.unsupportedMedia("no audio in \(url.lastPathComponent)")
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw FramesError.corruptMedia("audio has no duration")
        }
        return SourceAsset(
            fileName: url.lastPathComponent,
            kind: .video,
            duration: duration,
            displaySize: .zero,
            nominalFrameRate: 0,
            hasAudioTrack: true
        )
    }
}
