import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import OSLog
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Brings media into a session.
///
/// Import means three things and nothing else: copy the file into the session
/// directory, read enough metadata to describe it, and hand back a
/// `SourceAsset`. No transcoding, no thumbnail generation, no analysis — those
/// happen later and lazily, so choosing a video opens the editor immediately
/// instead of after a progress bar.
struct MediaImportService: Sendable {
    private var logger: Logger { FramesLog.importer }

    /// Content types the picker and the file importer accept.
    static let supportedContentTypes: [UTType] = [.movie, .video, .image, .livePhoto]

    // MARK: - Photos picker

    func importAsset(from item: PhotosPickerItem) async throws -> SourceAsset {
        let signpost = FramesLog.signposter.beginInterval("import")
        defer { FramesLog.signposter.endInterval("import", signpost) }

        let file: ImportedFile
        do {
            guard let loaded = try await item.loadTransferable(type: ImportedFile.self) else {
                throw FramesError.unsupportedMedia("picker returned no transferable file")
            }
            file = loaded
        } catch let error as FramesError {
            throw error
        } catch {
            // The most common cause by far is an asset that lives in iCloud and
            // could not be pulled down, so say that rather than surfacing the
            // framework's message.
            logger.error("Picker transfer failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.iCloudDownloadFailed
        }

        return try await describe(fileAt: file.url, kind: file.kind)
    }

    // MARK: - Files

    func importAsset(fromFileAt url: URL) async throws -> SourceAsset {
        let kind = Self.kind(of: url)
        guard let kind else {
            throw FramesError.unsupportedMedia("unrecognised type at \(url.lastPathComponent)")
        }
        let staged = try MediaStaging.stageSecurityScoped(url, kind: kind)
        return try await describe(fileAt: staged, kind: kind)
    }

    /// Imports a file that is already inside the session directory.
    func describeExisting(fileName: String, kind: MediaKind) async throws -> SourceAsset {
        try await describe(fileAt: SessionPaths.mediaURL(for: fileName), kind: kind)
    }

    static func kind(of url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .photo }
        return nil
    }

    // MARK: - Description

    private func describe(fileAt url: URL, kind: MediaKind) async throws -> SourceAsset {
        switch kind {
        case .video:
            return try await describeVideo(at: url)
        case .photo:
            return try describePhoto(at: url)
        }
    }

    private func describeVideo(at url: URL) async throws -> SourceAsset {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            guard let track = videoTracks.first else {
                throw FramesError.unsupportedMedia("no video track")
            }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let frameRate = try await track.load(.nominalFrameRate)

            // The displayed size is the natural size with the track's preferred
            // transform applied, which is what makes portrait video actually
            // report as portrait.
            let transformed = naturalSize.applying(preferredTransform)
            let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))

            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else {
                throw FramesError.corruptMedia("non-finite duration")
            }

            return SourceAsset(
                fileName: url.lastPathComponent,
                kind: .video,
                duration: seconds,
                displaySize: displaySize,
                nominalFrameRate: Double(frameRate),
                hasAudioTrack: !audioTracks.isEmpty
            )
        } catch let error as FramesError {
            throw error
        } catch {
            logger.error("Video probe failed: \(error.localizedDescription, privacy: .public)")
            throw FramesError.corruptMedia(error.localizedDescription)
        }
    }

    private func describePhoto(at url: URL) throws -> SourceAsset {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw FramesError.corruptMedia("image properties unavailable")
        }

        let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw FramesError.corruptMedia("zero-sized image")
        }

        // EXIF orientations 5–8 mean the stored pixels are rotated a quarter
        // turn from how the image should be shown.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let isQuarterTurned = (5...8).contains(orientation)
        let displaySize = isQuarterTurned
            ? CGSize(width: pixelHeight, height: pixelWidth)
            : CGSize(width: pixelWidth, height: pixelHeight)

        return SourceAsset(
            fileName: url.lastPathComponent,
            kind: .photo,
            duration: 0,
            displaySize: displaySize,
            nominalFrameRate: 0,
            hasAudioTrack: false
        )
    }

    // MARK: - Documents

    /// Builds the starting document for a freshly imported asset.
    func makeDocument(for asset: SourceAsset) -> EditDocument {
        switch asset.kind {
        case .photo:
            return EditDocument.photo(asset: asset)
        case .video:
            return EditDocument.video(asset: asset)
        }
    }
}
