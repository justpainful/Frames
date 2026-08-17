import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Photos
import UniformTypeIdentifiers

/// Where an export got to.
enum ExportProgress: Equatable, Sendable {
    case preparing
    case rendering(Double)
    case saving
    case finished(URL)
    case failed(FramesError)

    var fraction: Double {
        switch self {
        case .preparing: 0.02
        case .rendering(let value): 0.02 + value * 0.9
        case .saving: 0.95
        case .finished: 1
        case .failed: 0
        }
    }
}

/// Renders the finished file and puts it in the photo library.
///
/// The video path builds exactly the same composition the preview plays, with
/// `RenderQuality.final`, so what is written is what was on screen. Nothing in
/// the editor is "preview only".
actor ExportService {
    private let compositionEngine = CompositionEngine()
    private let imageEngine = ImageRenderEngine()
    private let logger = FramesLog.export

    /// Rough headroom check before starting. Running out of disk halfway
    /// through a 4K export wastes minutes, so it is worth one estimate.
    private static let minimumFreeBytes: Int64 = 250 * 1024 * 1024

    func export(
        document: EditDocument,
        settings: ExportSettings,
        onProgress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        let signpost = FramesLog.signposter.beginInterval("export")
        defer { FramesLog.signposter.endInterval("export", signpost) }

        onProgress(.preparing)
        try SessionPaths.createDirectories()
        SessionPaths.pruneScratch()

        if let available = SessionPaths.availableCapacity(), available < Self.minimumFreeBytes {
            throw FramesError.insufficientDiskSpace
        }

        switch document.kind {
        case .photo:
            return try await exportStill(document: document, settings: settings, onProgress: onProgress)
        case .video:
            return try await exportVideo(document: document, settings: settings, onProgress: onProgress)
        }
    }

    // MARK: - Stills

    private func exportStill(
        document: EditDocument,
        settings: ExportSettings,
        onProgress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        let url = SessionPaths.exportScratch
            .appendingPathComponent("Frames-\(UUID().uuidString).\(settings.stillFormat.fileExtension)")

        onProgress(.rendering(0.1))
        try await imageEngine.export(document: document, to: url, settings: settings)
        onProgress(.rendering(1))
        return url
    }

    // MARK: - Video

    private func exportVideo(
        document: EditDocument,
        settings: ExportSettings,
        onProgress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> URL {
        let sourceLongEdge = document.primaryAsset.map {
            max($0.displaySize.width, $0.displaySize.height)
        } ?? 1920
        let sourceFrameRate = document.primaryAsset?.nominalFrameRate ?? 30
        let resolved = settings.resolved(
            forSourceLongEdge: sourceLongEdge,
            sourceFrameRate: sourceFrameRate
        )

        // Build once at the export's own output size, so the compositor renders
        // straight to the final resolution instead of scaling afterwards.
        let previewBuild = try await compositionEngine.build(document: document, quality: .final)
        let targetLongEdge = resolved.resolution.longEdge(sourceLongEdge: sourceLongEdge)
        let outputSize = Self.scaled(previewBuild.outputSize, toLongEdge: targetLongEdge)

        let build = outputSize == previewBuild.outputSize
            ? previewBuild
            : try await compositionEngine.build(
                document: document,
                quality: .final,
                overrideOutputSize: outputSize
            )

        let frameRate = resolved.frameRate.value ?? build.frameRate
        let url = SessionPaths.exportScratch
            .appendingPathComponent("Frames-\(UUID().uuidString).mp4")

        let videoComposition = build.videoComposition.flatMap { composition -> AVVideoComposition? in
            guard let mutable = composition.mutableCopy() as? AVMutableVideoComposition else {
                return composition
            }
            mutable.frameDuration = CMTime(
                value: 1,
                timescale: CMTimeScale(max(frameRate.rounded(), 1))
            )
            return mutable
        }

        guard let session = AVAssetExportSession(
            asset: build.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw FramesError.exportFailed("no export session available")
        }
        session.videoComposition = videoComposition
        session.audioMix = build.audioMix
        session.shouldOptimizeForNetworkUse = true

        onProgress(.rendering(0))

        // `states(updateInterval:)` reports real progress and completes when the
        // write does, which is what lets the sheet show a bar rather than a
        // spinner.
        do {
            // The write and the progress stream run together: `states` reports
            // until the export finishes, so starting it first would deadlock.
            async let write: Void = session.export(to: url, as: .mp4)
            for await state in session.states(updateInterval: 0.25) {
                switch state {
                case .pending, .waiting:
                    onProgress(.rendering(0))
                case .exporting(let progress):
                    onProgress(.rendering(progress.fractionCompleted))
                @unknown default:
                    break
                }
            }
            try await write
        } catch {
            logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            throw FramesError.exportFailed(error.localizedDescription)
        }

        onProgress(.rendering(1))
        return url
    }

    private static func scaled(_ size: CGSize, toLongEdge longEdge: CGFloat) -> CGSize {
        let current = max(size.width, size.height)
        guard current > 0, longEdge > 0, abs(current - longEdge) > 1 else { return size }
        let factor = longEdge / current
        return CGSize(
            width: max((size.width * factor / 2).rounded() * 2, 16),
            height: max((size.height * factor / 2).rounded() * 2, 16)
        )
    }

    // MARK: - Photos

    /// Adds the finished file to the library.
    ///
    /// Uses the add-only authorisation, which is the least the app can ask for
    /// and all it needs.
    func saveToPhotos(_ url: URL, kind: MediaKind) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolved: PHAuthorizationStatus
        if status == .notDetermined {
            resolved = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolved = status
        }
        guard resolved == .authorized || resolved == .limited else {
            throw FramesError.photoLibraryAddPermissionDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(
                    with: kind == .video ? .video : .photo,
                    fileURL: url,
                    options: options
                )
            }
        } catch {
            logger.error("Save to Photos failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.saveToPhotosFailed(error.localizedDescription)
        }
    }

    /// Removes a finished render once the user is done with it.
    func discardRender(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        SessionPaths.pruneScratch()
    }
}
