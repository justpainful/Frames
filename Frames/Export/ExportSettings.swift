import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// What the user picks in the export sheet.
///
/// The basics are three choices with obvious names. Everything a codec-literate
/// person might want is behind Advanced, and nothing there is required to get a
/// good result — the defaults are the recommendation.
struct ExportSettings: Hashable, Sendable, Codable {

    enum Resolution: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case original
        case hd720
        case hd1080
        case qhd1440
        case uhd4K

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .original: String(localized: "Original", comment: "Export resolution")
            case .hd720: "720p"
            case .hd1080: "1080p"
            case .qhd1440: "1440p"
            case .uhd4K: "4K"
            }
        }

        /// Long edge in pixels, or the source's own long edge for `.original`.
        func longEdge(sourceLongEdge: CGFloat) -> CGFloat {
            switch self {
            case .original: max(sourceLongEdge, 64)
            case .hd720: 1280
            case .hd1080: 1920
            case .qhd1440: 2560
            case .uhd4K: 3840
            }
        }

        /// Offering an upscale to 4K from a 720p source is a lie; the sheet
        /// filters the list with this.
        func isSensible(forSourceLongEdge sourceLongEdge: CGFloat) -> Bool {
            self == .original || longEdge(sourceLongEdge: sourceLongEdge) <= sourceLongEdge * 1.05
        }
    }

    enum FrameRate: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case original
        case fps24
        case fps25
        case fps30
        case fps50
        case fps60

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .original: String(localized: "Original", comment: "Export frame rate")
            case .fps24: "24"
            case .fps25: "25"
            case .fps30: "30"
            case .fps50: "50"
            case .fps60: "60"
            }
        }

        var value: Double? {
            switch self {
            case .original: nil
            case .fps24: 24
            case .fps25: 25
            case .fps30: 30
            case .fps50: 50
            case .fps60: 60
            }
        }

        /// Never offer a frame rate the source cannot supply.
        func isSensible(forSourceFrameRate source: Double) -> Bool {
            guard let value else { return true }
            return source <= 0 || value <= source + 0.5
        }
    }

    enum Quality: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case smaller
        case balanced
        case best

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .smaller: String(localized: "Smaller", comment: "Export quality")
            case .balanced: String(localized: "Balanced", comment: "Export quality")
            case .best: String(localized: "Best", comment: "Export quality")
            }
        }

        var stillCompressionQuality: Double {
            switch self {
            case .smaller: 0.7
            case .balanced: 0.86
            case .best: 0.96
            }
        }

        /// Bits per pixel per frame, the basis for the video bitrate estimate.
        var bitsPerPixel: Double {
            switch self {
            case .smaller: 0.055
            case .balanced: 0.11
            case .best: 0.20
            }
        }
    }

    enum VideoCodec: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case h264
        case hevc

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            }
        }

        var detail: String {
            switch self {
            case .h264: String(localized: "Plays everywhere", comment: "Codec detail")
            case .hevc: String(localized: "Smaller files, modern devices", comment: "Codec detail")
            }
        }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            }
        }
    }

    enum StillFormat: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case heic
        case jpeg
        case png

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .heic: "HEIF"
            case .jpeg: "JPEG"
            case .png: "PNG"
            }
        }

        var fileExtension: String {
            switch self {
            case .heic: "heic"
            case .jpeg: "jpg"
            case .png: "png"
            }
        }

        var contentType: UTType {
            switch self {
            case .heic: .heic
            case .jpeg: .jpeg
            case .png: .png
            }
        }
    }

    enum AudioQuality: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case standard
        case high

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .standard: String(localized: "Standard", comment: "Audio quality")
            case .high: String(localized: "High", comment: "Audio quality")
            }
        }

        var bitRate: Int {
            switch self {
            case .standard: 128_000
            case .high: 256_000
            }
        }
    }

    var resolution: Resolution
    var frameRate: FrameRate
    var quality: Quality
    var videoCodec: VideoCodec
    var stillFormat: StillFormat
    var audioQuality: AudioQuality
    /// Overrides the computed bitrate when the user has set one explicitly.
    var customBitrate: Int?
    /// Keeps the source's wide-gamut colour rather than converting to sRGB.
    var preservesWideColor: Bool

    init(
        resolution: Resolution = .original,
        frameRate: FrameRate = .original,
        quality: Quality = .balanced,
        videoCodec: VideoCodec = .hevc,
        stillFormat: StillFormat = .heic,
        audioQuality: AudioQuality = .standard,
        customBitrate: Int? = nil,
        preservesWideColor: Bool = true
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
        self.videoCodec = videoCodec
        self.stillFormat = stillFormat
        self.audioQuality = audioQuality
        self.customBitrate = customBitrate
        self.preservesWideColor = preservesWideColor
    }

    static let `default` = ExportSettings()

    /// Bitrate for a given output, from the quality setting or the override.
    func videoBitrate(for size: CGSize, frameRate: Double) -> Int {
        if let customBitrate { return max(customBitrate, 200_000) }
        let pixels = Double(size.width * size.height)
        let estimate = pixels * max(frameRate, 1) * quality.bitsPerPixel
        // HEVC reaches the same quality at meaningfully lower bitrates.
        let codecFactor = videoCodec == .hevc ? 0.68 : 1.0
        return Int(max(min(estimate * codecFactor, 120_000_000), 400_000))
    }

    /// Rough file size in bytes, shown in the sheet so the choice is informed.
    func estimatedFileSize(duration: TimeInterval, size: CGSize, frameRate: Double) -> Int64 {
        guard duration > 0 else { return 0 }
        let video = Double(videoBitrate(for: size, frameRate: frameRate)) * duration / 8
        let audio = Double(audioQuality.bitRate) * duration / 8
        return Int64(video + audio)
    }

    /// The options the sheet should offer for this source.
    static func availableResolutions(sourceLongEdge: CGFloat) -> [Resolution] {
        Resolution.allCases.filter { $0.isSensible(forSourceLongEdge: sourceLongEdge) }
    }

    static func availableFrameRates(sourceFrameRate: Double) -> [FrameRate] {
        FrameRate.allCases.filter { $0.isSensible(forSourceFrameRate: sourceFrameRate) }
    }

    /// Corrects a settings value against what the source can actually provide,
    /// so a setting carried over from a previous export cannot silently produce
    /// an upscale.
    func resolved(forSourceLongEdge sourceLongEdge: CGFloat, sourceFrameRate: Double) -> ExportSettings {
        var copy = self
        if !resolution.isSensible(forSourceLongEdge: sourceLongEdge) {
            copy.resolution = .original
        }
        if !frameRate.isSensible(forSourceFrameRate: sourceFrameRate) {
            copy.frameRate = .original
        }
        return copy
    }
}
