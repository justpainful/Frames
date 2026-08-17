import CoreGraphics
import Foundation
@testable import Frames

/// Deterministic documents for the model tests.
///
/// None of these touch the file system: the timeline is pure value math, and
/// keeping the tests free of real media is what makes them fast and makes the
/// repository free of committed video.
enum TestDocuments {
    static func videoAsset(duration: TimeInterval = 15, name: String = "test.mov") -> SourceAsset {
        SourceAsset(
            fileName: name,
            kind: .video,
            duration: duration,
            displaySize: CGSize(width: 1920, height: 1080),
            nominalFrameRate: 30,
            hasAudioTrack: true
        )
    }

    static func photoAsset(name: String = "test.jpg") -> SourceAsset {
        SourceAsset(
            fileName: name,
            kind: .photo,
            duration: 0,
            displaySize: CGSize(width: 4032, height: 3024)
        )
    }

    /// A single 15-second clip, which is the shape of almost every real edit.
    static func singleClipVideo(duration: TimeInterval = 15) -> EditDocument {
        EditDocument.video(asset: videoAsset(duration: duration))
    }

    /// Three back-to-back five-second clips from one asset.
    static func threeClipVideo() -> EditDocument {
        let asset = videoAsset(duration: 15)
        var document = EditDocument(kind: .video, assets: [asset])
        document.videoTrack = (0..<3).map { index in
            VideoClip(
                assetID: asset.id,
                source: TimeRange(start: Double(index) * 5, duration: 5)
            )
        }
        return document
    }

    static func photo() -> EditDocument {
        EditDocument.photo(asset: photoAsset())
    }
}
