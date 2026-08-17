#if DEBUG
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import UIKit

/// Deterministic media for automated tests.
///
/// UI tests cannot drive the system photo picker, so the app accepts a launch
/// argument that imports a generated fixture instead. The fixtures are drawn at
/// runtime rather than committed, which keeps the repository free of binary
/// media and makes the tests independent of anyone's photo library.
///
/// This entire file is compiled out of release builds, so there is no path from
/// a shipping binary into any of it.
enum UITestFixtures {
    enum Fixture: String, CaseIterable {
        case samplePhoto = "sample-photo"
        case sampleVideo = "sample-video"
    }

    static let launchArgument = "-FRAMES_UI_TEST_FIXTURE"
    static let resetArgument = "-FRAMES_UI_RESET"

    /// True when the test run wants a clean slate, so a leftover recoverable
    /// session from a previous test cannot interrupt this one.
    static func shouldResetState() -> Bool {
        ProcessInfo.processInfo.arguments.contains(resetArgument)
    }

    /// Reads the requested fixture from the launch arguments.
    static func requestedFixture() -> Fixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: launchArgument),
              index + 1 < arguments.count
        else { return nil }
        return Fixture(rawValue: arguments[index + 1])
    }

    static func makeAsset(_ fixture: Fixture) async throws -> SourceAsset {
        try SessionPaths.createDirectories()
        switch fixture {
        case .samplePhoto:
            let url = try writePhoto()
            return try await MediaImportService().describeExisting(fileName: url.lastPathComponent, kind: .photo)
        case .sampleVideo:
            let url = try await writeVideo()
            return try await MediaImportService().describeExisting(fileName: url.lastPathComponent, kind: .video)
        }
    }

    // MARK: - Drawing

    private static let photoSize = CGSize(width: 1200, height: 1600)
    private static let videoSize = CGSize(width: 720, height: 1280)
    private static let videoDuration: TimeInterval = 6
    private static let videoFrameRate: Int32 = 30

    /// A recognisable test card: a gradient, a grid, and a large centred
    /// numeral, so a failing screenshot is readable at a glance.
    private static func drawFrame(index: Int, size: CGSize) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            let colors = [
                UIColor(red: 0.10, green: 0.16, blue: 0.30, alpha: 1).cgColor,
                UIColor(red: 0.55, green: 0.25, blue: 0.35, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            UIColor(white: 1, alpha: 0.16).setStroke()
            let path = UIBezierPath()
            let step = size.width / 8
            var x: CGFloat = step
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = step
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            path.lineWidth = 2
            path.stroke()

            let label = "\(index)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.width * 0.34, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9)
            ]
            let bounds = label.size(withAttributes: attributes)
            label.draw(
                at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2),
                withAttributes: attributes
            )
        }
        return image.cgImage
    }

    private static func writePhoto() throws -> URL {
        guard let cgImage = drawFrame(index: 1, size: photoSize) else {
            throw FramesError.importFailed("fixture render failed")
        }
        let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
        guard let data else { throw FramesError.importFailed("fixture encode failed") }
        let url = SessionPaths.mediaURL(for: "fixture-photo.jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func writeVideo() async throws -> URL {
        let url = SessionPaths.mediaURL(for: "fixture-video.mov")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else { throw FramesError.importFailed("fixture writer rejected input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FramesError.importFailed("fixture writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(videoDuration) * Int(videoFrameRate)
        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw FramesError.importFailed("fixture pixel buffer pool unavailable")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let pixelBuffer = buffer else {
                throw FramesError.importFailed("fixture pixel buffer unavailable")
            }
            // One numeral per second makes it obvious in a screenshot which
            // moment the playhead is showing.
            let second = frame / Int(videoFrameRate)
            try render(second: second, into: pixelBuffer)
            let time = CMTime(value: CMTimeValue(frame), timescale: videoFrameRate)
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FramesError.importFailed("fixture write incomplete")
        }
        return url
    }

    private static func render(second: Int, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw FramesError.importFailed("fixture buffer had no base address")
        }
        guard let context = CGContext(
            data: base,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw FramesError.importFailed("fixture context unavailable")
        }
        guard let image = drawFrame(index: second, size: videoSize) else {
            throw FramesError.importFailed("fixture frame render failed")
        }
        context.draw(image, in: CGRect(origin: .zero, size: videoSize))
    }
}
#endif
