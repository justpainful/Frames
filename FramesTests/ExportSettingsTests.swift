import CoreGraphics
import Foundation
import Testing
@testable import Frames

@Suite("Export settings")
struct ExportSettingsTests {

    @Test("Original resolution follows the source")
    func originalFollowsSource() {
        #expect(ExportSettings.Resolution.original.longEdge(sourceLongEdge: 3024) == 3024)
        #expect(ExportSettings.Resolution.hd1080.longEdge(sourceLongEdge: 3024) == 1920)
    }

    @Test("Upscales are not offered")
    func upscalesAreFiltered() {
        let offered = ExportSettings.availableResolutions(sourceLongEdge: 1280)
        #expect(offered.contains(.original))
        #expect(offered.contains(.hd720))
        #expect(!offered.contains(.uhd4K), "offering 4K from a 720p source would be a lie")
        #expect(!offered.contains(.qhd1440))
    }

    @Test("Frame rates above the source are not offered")
    func frameRatesAreFiltered() {
        let offered = ExportSettings.availableFrameRates(sourceFrameRate: 30)
        #expect(offered.contains(.fps30))
        #expect(offered.contains(.fps24))
        #expect(!offered.contains(.fps60))
    }

    @Test("A source with no known frame rate offers everything")
    func unknownFrameRateOffersAll() {
        let offered = ExportSettings.availableFrameRates(sourceFrameRate: 0)
        #expect(offered.count == ExportSettings.FrameRate.allCases.count)
    }

    @Test("Settings carried over from a previous export are corrected")
    func resolvedAgainstSource() {
        let settings = ExportSettings(resolution: .uhd4K, frameRate: .fps60)
        let resolved = settings.resolved(forSourceLongEdge: 1280, sourceFrameRate: 30)
        #expect(resolved.resolution == .original)
        #expect(resolved.frameRate == .original)
    }

    @Test("Settings that suit the source are left alone")
    func resolvedLeavesValidSettings() {
        let settings = ExportSettings(resolution: .hd1080, frameRate: .fps30)
        let resolved = settings.resolved(forSourceLongEdge: 3840, sourceFrameRate: 60)
        #expect(resolved.resolution == .hd1080)
        #expect(resolved.frameRate == .fps30)
    }

    @Test("Bitrate rises with quality and with pixels")
    func bitrateScales() {
        let size = CGSize(width: 1920, height: 1080)
        let smaller = ExportSettings(quality: .smaller).videoBitrate(for: size, frameRate: 30)
        let balanced = ExportSettings(quality: .balanced).videoBitrate(for: size, frameRate: 30)
        let best = ExportSettings(quality: .best).videoBitrate(for: size, frameRate: 30)
        #expect(smaller < balanced)
        #expect(balanced < best)

        let large = ExportSettings(quality: .balanced)
            .videoBitrate(for: CGSize(width: 3840, height: 2160), frameRate: 30)
        #expect(large > balanced)
    }

    @Test("HEVC is given a lower bitrate for the same quality")
    func codecAffectsBitrate() {
        let size = CGSize(width: 1920, height: 1080)
        let h264 = ExportSettings(videoCodec: .h264).videoBitrate(for: size, frameRate: 30)
        let hevc = ExportSettings(videoCodec: .hevc).videoBitrate(for: size, frameRate: 30)
        #expect(hevc < h264)
    }

    @Test("A custom bitrate overrides the estimate but stays sane")
    func customBitrate() {
        var settings = ExportSettings()
        settings.customBitrate = 5_000_000
        #expect(settings.videoBitrate(for: CGSize(width: 1920, height: 1080), frameRate: 30) == 5_000_000)

        settings.customBitrate = 1
        #expect(settings.videoBitrate(for: CGSize(width: 1920, height: 1080), frameRate: 30) == 200_000)
    }

    @Test("Bitrate is bounded at both ends")
    func bitrateIsBounded() {
        let tiny = ExportSettings(quality: .smaller)
            .videoBitrate(for: CGSize(width: 16, height: 16), frameRate: 1)
        #expect(tiny >= 400_000)

        let huge = ExportSettings(quality: .best)
            .videoBitrate(for: CGSize(width: 8192, height: 8192), frameRate: 120)
        #expect(huge <= 120_000_000)
    }

    @Test("A zero-length edit has no estimated size")
    func emptyEstimate() {
        let estimate = ExportSettings.default.estimatedFileSize(
            duration: 0,
            size: CGSize(width: 1920, height: 1080),
            frameRate: 30
        )
        #expect(estimate == 0)
    }

    @Test("The estimate grows with duration")
    func estimateGrowsWithDuration() {
        let size = CGSize(width: 1920, height: 1080)
        let short = ExportSettings.default.estimatedFileSize(duration: 5, size: size, frameRate: 30)
        let long = ExportSettings.default.estimatedFileSize(duration: 50, size: size, frameRate: 30)
        #expect(long > short * 8)
    }

    @Test("Still compression quality rises with the quality setting")
    func stillQuality() {
        #expect(ExportSettings.Quality.smaller.stillCompressionQuality
                < ExportSettings.Quality.balanced.stillCompressionQuality)
        #expect(ExportSettings.Quality.balanced.stillCompressionQuality
                < ExportSettings.Quality.best.stillCompressionQuality)
    }

    @Test("Settings survive a round trip")
    func codingRoundTrip() throws {
        let settings = ExportSettings(
            resolution: .qhd1440,
            frameRate: .fps50,
            quality: .best,
            videoCodec: .h264,
            stillFormat: .png,
            audioQuality: .high,
            customBitrate: 12_000_000,
            preservesWideColor: false
        )
        let decoded = try FramesJSON.decoder.decode(
            ExportSettings.self,
            from: FramesJSON.encoder.encode(settings)
        )
        #expect(decoded == settings)
    }
}

@Suite("Geometry")
struct GeometryTests {

    @Test("Vision rects flip into composition space and back")
    func visionRoundTrip() {
        let visionRect = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.25)
        let converted = CoordinateSpaceConverter.fromVision(visionRect)
        #expect(abs(converted.minX - 0.2) < 0.0001)
        // Vision's origin is bottom-left, so a rect near the bottom becomes a
        // rect near the top.
        #expect(abs(converted.minY - 0.65) < 0.0001)
        #expect(CoordinateSpaceConverter.toVision(converted) == visionRect)
    }

    @Test("Normalized rects become pixel rects with a bottom-left origin")
    func imageRectConversion() {
        let rect = CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5)
        let pixels = CoordinateSpaceConverter.imageRect(from: rect, in: CGSize(width: 100, height: 200))
        #expect(pixels.minX == 25)
        #expect(pixels.width == 50)
        #expect(pixels.height == 100)
        #expect(pixels.minY == 100, "the top half in model space is the top half in image space")
    }

    @Test("Crop output ratio accounts for quarter turns")
    func cropAspect() {
        var crop = CropState()
        #expect(abs(crop.outputAspectRatio(sourceAspectRatio: 16.0 / 9) - 16.0 / 9) < 0.0001)

        crop.quarterTurns = 1
        #expect(abs(crop.outputAspectRatio(sourceAspectRatio: 16.0 / 9) - 9.0 / 16) < 0.0001)
    }

    @Test("Normalising a crop keeps it inside the frame")
    func cropNormalisation() {
        var crop = CropState(rect: CGRect(x: -0.5, y: 0.9, width: 3, height: 3))
        crop.normalize()
        #expect(crop.rect.minX >= 0)
        #expect(crop.rect.minY >= 0)
        #expect(crop.rect.maxX <= 1.0001)
        #expect(crop.rect.maxY <= 1.0001)
    }

    @Test("Straightening is limited to a usable range")
    func straightenIsClamped() {
        var crop = CropState(straightenAngle: 3)
        crop.normalize()
        #expect(crop.straightenAngle <= CropState.maximumStraightenAngle + 0.0001)

        crop.straightenAngle = -3
        crop.normalize()
        #expect(crop.straightenAngle >= -CropState.maximumStraightenAngle - 0.0001)
    }

    @Test("Layer transforms cannot be dragged into uselessness")
    func transformClamping() {
        var transform = LayerTransform(position: CGPoint(x: 9, y: -9), scale: 500, opacity: 4)
        transform.clampToUsableBounds()
        #expect(transform.position.x <= 1.25)
        #expect(transform.position.y >= -0.25)
        #expect(transform.scale <= 12)
        #expect(transform.opacity <= 1)
    }

    @Test("An extent has to be usable before anything is sized from it")
    func renderableExtents() {
        #expect(CGRect(x: 0, y: 0, width: 10, height: 10).isRenderable)
        #expect(!CGRect.null.isRenderable)
        #expect(!CGRect.infinite.isRenderable)
        #expect(!CGRect(x: 0, y: 0, width: 0, height: 10).isRenderable)
    }
}
