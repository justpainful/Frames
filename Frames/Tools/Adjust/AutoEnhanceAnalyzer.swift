import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Works out a sensible starting point for the Adjust sliders.
///
/// Auto is not a hidden one-way transformation in Frames: it measures the
/// frame, produces an ordinary `AdjustmentSet`, and hands it to the same
/// sliders the user would have moved themselves. Every value it chooses is
/// visible and editable afterwards, and undoing it is one step.
enum AutoEnhanceAnalyzer {

    /// Statistics the decisions are made from.
    struct Measurements: Sendable, Equatable {
        /// Mean luminance, 0...1.
        var meanLuminance: Double
        /// Luminance at roughly the 2nd and 98th percentiles.
        var shadowLevel: Double
        var highlightLevel: Double
        /// Mean saturation, 0...1.
        var meanSaturation: Double
        /// Difference between the mean channel values, as a warm/cool cue.
        var redBlueBalance: Double
    }

    /// Reads the frame. Cheap: it works from a heavily reduced image, because
    /// none of these statistics need pixels.
    static func measure(_ image: CIImage, context: CIContext) -> Measurements? {
        let extent = image.extent
        guard extent.isRenderable else { return nil }

        guard let average = areaAverage(of: image, extent: extent, context: context) else { return nil }
        let mean = luminance(average)

        // A 16-bucket histogram is enough to find where the tails sit without
        // pulling a full histogram off the GPU.
        let histogram = luminanceHistogram(of: image, extent: extent, context: context)
        let shadow = percentile(0.02, in: histogram) ?? max(mean - 0.3, 0)
        let highlight = percentile(0.98, in: histogram) ?? min(mean + 0.3, 1)

        let maximumChannel = max(average.red, max(average.green, average.blue))
        let minimumChannel = min(average.red, min(average.green, average.blue))
        let saturation = maximumChannel > 0.001 ? (maximumChannel - minimumChannel) / maximumChannel : 0

        return Measurements(
            meanLuminance: mean,
            shadowLevel: shadow,
            highlightLevel: highlight,
            meanSaturation: saturation,
            redBlueBalance: average.red - average.blue
        )
    }

    /// Turns measurements into slider values.
    ///
    /// The rules are deliberately conservative. Auto should make a picture
    /// better often and worse never, which means small moves and a hard cap on
    /// every parameter.
    static func adjustments(for measurements: Measurements) -> AdjustmentSet {
        var set = AdjustmentSet()

        // Aim for a mean a little under the middle: pictures read better
        // slightly darker than mathematically neutral.
        let targetMean = 0.46
        let exposureError = targetMean - measurements.meanLuminance
        if abs(exposureError) > 0.03 {
            set[.exposure] = clamp(exposureError * 1.5, limit: 0.55)
        }

        // If the tails are well inside the range, the picture is flat.
        let range = measurements.highlightLevel - measurements.shadowLevel
        if range < 0.72 {
            set[.contrast] = clamp((0.85 - range) * 0.8, limit: 0.4)
        } else if range > 0.97 {
            // Already clipping at both ends; pull the extremes in instead.
            set[.highlights] = -0.2
            set[.shadows] = 0.18
        }

        // Lifted blacks are the most common fault in phone footage.
        if measurements.shadowLevel > 0.12 {
            set[.blackPoint] = clamp((measurements.shadowLevel - 0.08) * 1.3, limit: 0.45)
        }
        if measurements.shadowLevel < 0.02, measurements.meanLuminance < 0.4 {
            set[.shadows] = clamp((0.4 - measurements.meanLuminance) * 0.9, limit: 0.5)
        }
        if measurements.highlightLevel > 0.97 {
            set[.highlights] = clamp(-(measurements.highlightLevel - 0.9) * 2.2, limit: 0.5)
        }

        // Vibrance rather than saturation: it leaves already-saturated colour
        // and skin alone.
        if measurements.meanSaturation < 0.28 {
            set[.vibrance] = clamp((0.34 - measurements.meanSaturation) * 1.1, limit: 0.35)
        }

        // Only correct a cast that is actually visible.
        if abs(measurements.redBlueBalance) > 0.045 {
            set[.warmth] = clamp(-measurements.redBlueBalance * 1.6, limit: 0.3)
        }

        // A little local contrast makes the result read as sharper without
        // touching the noise floor.
        set[.definition] = 0.16

        return set
    }

    static func analyse(_ image: CIImage, context: CIContext) -> AdjustmentSet {
        guard let measurements = measure(image, context: context) else { return AdjustmentSet() }
        return adjustments(for: measurements)
    }

    // MARK: - Measurement helpers

    private static func clamp(_ value: Double, limit: Double) -> Double {
        min(max(value, -limit), limit)
    }

    private static func luminance(_ colour: RGBAColor) -> Double {
        0.2126 * colour.red + 0.7152 * colour.green + 0.0722 * colour.blue
    }

    private static func areaAverage(of image: CIImage, extent: CGRect, context: CIContext) -> RGBAColor? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent
        guard let output = filter.outputImage else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return RGBAColor(
            red: Double(bytes[0]) / 255,
            green: Double(bytes[1]) / 255,
            blue: Double(bytes[2]) / 255,
            alpha: Double(bytes[3]) / 255
        )
    }

    /// Sixteen luminance buckets, normalised to sum to 1.
    private static func luminanceHistogram(
        of image: CIImage,
        extent: CGRect,
        context: CIContext
    ) -> [Double] {
        let bucketCount = 16
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = extent
        filter.count = bucketCount
        filter.scale = 1
        guard let output = filter.outputImage else { return [] }

        var bytes = [UInt8](repeating: 0, count: bucketCount * 4)
        context.render(
            output,
            toBitmap: &bytes,
            rowBytes: bucketCount * 4,
            bounds: CGRect(x: 0, y: 0, width: bucketCount, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        var buckets: [Double] = []
        buckets.reserveCapacity(bucketCount)
        for index in 0..<bucketCount {
            let red = Double(bytes[index * 4]) / 255
            let green = Double(bytes[index * 4 + 1]) / 255
            let blue = Double(bytes[index * 4 + 2]) / 255
            buckets.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }
        let total = buckets.reduce(0, +)
        guard total > 0.0001 else { return [] }
        return buckets.map { $0 / total }
    }

    /// The luminance below which `fraction` of the picture falls.
    private static func percentile(_ fraction: Double, in histogram: [Double]) -> Double? {
        guard !histogram.isEmpty else { return nil }
        var cumulative: Double = 0
        for (index, value) in histogram.enumerated() {
            cumulative += value
            if cumulative >= fraction {
                return (Double(index) + 0.5) / Double(histogram.count)
            }
        }
        return 1
    }
}
