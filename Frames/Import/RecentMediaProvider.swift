import AVFoundation
import Foundation
import Observation
import OSLog
import Photos
import UIKit

/// One entry in the chooser's recents strip.
struct RecentMediaItem: Identifiable, Hashable {
    let id: String
    let kind: MediaKind
    let duration: TimeInterval
    let image: UIImage
}

/// Supplies the small strip of recent photos and videos on the chooser.
///
/// Deliberately opt-in. Frames does its job through the system picker, which
/// needs no permission at all, so the app never asks for library access on
/// launch. The strip only appears if the user has already granted access, or
/// taps to turn it on.
@MainActor
@Observable
final class RecentMediaProvider {
    private(set) var items: [RecentMediaItem] = []
    private(set) var isLoading = false

    /// Whether the strip can be shown without asking for anything.
    var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    var canRequestAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
    }

    private let imageManager = PHCachingImageManager()
    private let logger = FramesLog.importer
    private let limit = 12

    func loadIfAuthorized() async {
        guard isAuthorized, items.isEmpty, !isLoading else { return }
        await load()
    }

    func requestAccessAndLoad() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        await load()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        let targetSize = CGSize(width: 240, height: 240)
        var loaded: [RecentMediaItem] = []
        for asset in assets {
            guard let image = await requestThumbnail(for: asset, targetSize: targetSize) else { continue }
            loaded.append(
                RecentMediaItem(
                    id: asset.localIdentifier,
                    kind: asset.mediaType == .video ? .video : .photo,
                    duration: asset.duration,
                    image: image
                )
            )
        }
        items = loaded
    }

    private func requestThumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                guard !isDegraded, !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Loads the full asset behind a recents thumbnail, ready for editing.
    func loadAsset(for item: RecentMediaItem) async throws -> SourceAsset {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
        guard let asset = result.firstObject else {
            throw FramesError.importFailed("recent item no longer exists")
        }

        switch asset.mediaType {
        case .video:
            let url = try await exportVideoURL(for: asset)
            let staged = try MediaStaging.stage(url, kind: .video)
            return try await MediaImportService().describeExisting(
                fileName: staged.lastPathComponent, kind: .video
            )
        case .image:
            let url = try await imageURL(for: asset)
            let staged = try MediaStaging.stage(url, kind: .photo)
            return try await MediaImportService().describeExisting(
                fileName: staged.lastPathComponent, kind: .photo
            )
        default:
            throw FramesError.unsupportedMedia("unsupported media type")
        }
    }

    private func exportVideoURL(for asset: PHAsset) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                if let urlAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: urlAsset.url)
                } else {
                    continuation.resume(throwing: FramesError.iCloudDownloadFailed)
                }
            }
        }
    }

    private func imageURL(for asset: PHAsset) async throws -> URL {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                if let url = input?.fullSizeImageURL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: FramesError.iCloudDownloadFailed)
                }
            }
        }
    }
}
