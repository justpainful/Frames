import Foundation

/// Every failure the user can actually see.
///
/// The associated values carry the technical detail for the log; the
/// user-facing strings stay short, specific and free of framework vocabulary.
enum FramesError: Error, Identifiable, Equatable {
    case unsupportedMedia(String)
    case corruptMedia(String)
    case importFailed(String)
    case iCloudDownloadFailed
    case renderFailed(String)
    case exportFailed(String)
    case insufficientDiskSpace
    case microphonePermissionDenied
    case cameraPermissionDenied
    case cameraUnavailable
    case photoLibraryAddPermissionDenied
    case saveToPhotosFailed(String)
    case visionUnavailable(String)
    case sessionRecoveryFailed(String)
    case cancelled

    var id: String { logDescription }

    /// Short title for an alert.
    var title: String {
        switch self {
        case .unsupportedMedia: String(localized: "Unsupported Media", comment: "Error title")
        case .corruptMedia: String(localized: "Media Can’t Be Read", comment: "Error title")
        case .importFailed: String(localized: "Import Failed", comment: "Error title")
        case .iCloudDownloadFailed: String(localized: "Download Failed", comment: "Error title")
        case .renderFailed: String(localized: "Preview Failed", comment: "Error title")
        case .exportFailed: String(localized: "Export Failed", comment: "Error title")
        case .insufficientDiskSpace: String(localized: "Not Enough Space", comment: "Error title")
        case .microphonePermissionDenied: String(localized: "Microphone Access Off", comment: "Error title")
        case .cameraPermissionDenied: String(localized: "Camera Access Off", comment: "Error title")
        case .cameraUnavailable: String(localized: "No Camera Available", comment: "Error title")
        case .photoLibraryAddPermissionDenied: String(localized: "Photos Access Off", comment: "Error title")
        case .saveToPhotosFailed: String(localized: "Couldn’t Save", comment: "Error title")
        case .visionUnavailable: String(localized: "Detection Unavailable", comment: "Error title")
        case .sessionRecoveryFailed: String(localized: "Couldn’t Recover Edit", comment: "Error title")
        case .cancelled: String(localized: "Cancelled", comment: "Error title")
        }
    }

    /// One sentence the user can act on. No error codes, no framework names.
    var message: String {
        switch self {
        case .unsupportedMedia:
            String(localized: "Frames can’t edit this kind of file. Try a photo or video from your library.",
                   comment: "Error message")
        case .corruptMedia:
            String(localized: "This file appears to be damaged and can’t be opened.", comment: "Error message")
        case .importFailed:
            String(localized: "That item couldn’t be brought into Frames. Try choosing it again.",
                   comment: "Error message")
        case .iCloudDownloadFailed:
            String(localized: "This item is stored in iCloud and couldn’t be downloaded. Check your connection and try again.",
                   comment: "Error message")
        case .renderFailed:
            String(localized: "The preview couldn’t be drawn. Undo the last change and try again.",
                   comment: "Error message")
        case .exportFailed:
            String(localized: "The export didn’t finish. Your edit is safe — try exporting again.",
                   comment: "Error message")
        case .insufficientDiskSpace:
            String(localized: "There isn’t enough free space on this iPhone to finish. Free up some space and try again.",
                   comment: "Error message")
        case .microphonePermissionDenied:
            String(localized: "Frames needs microphone access to record a voiceover. You can turn it on in Settings.",
                   comment: "Error message")
        case .cameraPermissionDenied:
            String(localized: "Frames needs camera access to record. You can turn it on in Settings.",
                   comment: "Error message")
        case .cameraUnavailable:
            String(localized: "This device has no camera Frames can use. Choose a photo or video from your library instead.",
                   comment: "Error message")
        case .photoLibraryAddPermissionDenied:
            String(localized: "Frames needs permission to add photos and videos to your library. You can turn it on in Settings.",
                   comment: "Error message")
        case .saveToPhotosFailed:
            String(localized: "The finished file couldn’t be added to your library. It’s still available to share.",
                   comment: "Error message")
        case .visionUnavailable:
            String(localized: "Nothing could be detected in this frame. Try a different frame, or select the area by hand.",
                   comment: "Error message")
        case .sessionRecoveryFailed:
            String(localized: "The unsaved edit couldn’t be reopened, so it was discarded.", comment: "Error message")
        case .cancelled:
            String(localized: "That operation was stopped before it finished.", comment: "Error message")
        }
    }

    /// Detail kept out of the interface and written to the log instead.
    var logDescription: String {
        switch self {
        case .unsupportedMedia(let detail): "unsupportedMedia(\(detail))"
        case .corruptMedia(let detail): "corruptMedia(\(detail))"
        case .importFailed(let detail): "importFailed(\(detail))"
        case .iCloudDownloadFailed: "iCloudDownloadFailed"
        case .renderFailed(let detail): "renderFailed(\(detail))"
        case .exportFailed(let detail): "exportFailed(\(detail))"
        case .insufficientDiskSpace: "insufficientDiskSpace"
        case .microphonePermissionDenied: "microphonePermissionDenied"
        case .cameraPermissionDenied: "cameraPermissionDenied"
        case .cameraUnavailable: "cameraUnavailable"
        case .photoLibraryAddPermissionDenied: "photoLibraryAddPermissionDenied"
        case .saveToPhotosFailed(let detail): "saveToPhotosFailed(\(detail))"
        case .visionUnavailable(let detail): "visionUnavailable(\(detail))"
        case .sessionRecoveryFailed(let detail): "sessionRecoveryFailed(\(detail))"
        case .cancelled: "cancelled"
        }
    }

    /// True when the sensible resolution is a trip to Settings.
    var suggestsSettings: Bool {
        switch self {
        case .microphonePermissionDenied, .cameraPermissionDenied, .photoLibraryAddPermissionDenied: true
        default: false
        }
    }
}
