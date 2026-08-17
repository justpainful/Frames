import CoreImage
import Foundation
import Metal
import OSLog

/// The shared Core Image contexts.
///
/// Creating a `CIContext` allocates a Metal command queue and a texture cache;
/// creating one per operation is the single most common way to make a Core
/// Image pipeline slow. Frames creates two, once, and reuses them for
/// everything: preview and export.
final class RenderContext: @unchecked Sendable {
    static let shared = RenderContext()

    /// Used for on-screen previews. Working in a smaller, non-linear space and
    /// skipping the software fallback keeps interactive edits responsive.
    let preview: CIContext

    /// Used for final renders. Works in extended linear sRGB so highlights
    /// survive the filter chain, and asks for the highest quality downsampling.
    let export: CIContext

    let metalDevice: MTLDevice?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        metalDevice = device

        let previewOptions: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .highQualityDownsample: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ]
        let exportOptions: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .highQualityDownsample: true,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ]

        if let device {
            preview = CIContext(mtlDevice: device, options: previewOptions)
            export = CIContext(mtlDevice: device, options: exportOptions)
        } else {
            // Simulators without a Metal device, and any future configuration
            // where Metal is unavailable, still need to render.
            preview = CIContext(options: previewOptions)
            export = CIContext(options: exportOptions)
            FramesLog.render.notice("No Metal device; Core Image is running on the CPU path.")
        }
    }

    func context(for quality: RenderQuality) -> CIContext {
        quality == .final ? export : preview
    }

    /// Drops cached intermediates. Called on a memory warning and after export.
    func clearCaches() {
        preview.clearCaches()
        export.clearCaches()
    }
}

/// How carefully a frame should be rendered.
enum RenderQuality: Hashable, Sendable {
    /// Interactive: skips the most expensive stages while a gesture is in
    /// flight, so dragging a slider stays at display rate.
    case interactive
    /// What the user sees when they let go.
    case preview
    /// What is written to the exported file.
    case final

    /// Effects that cost more than they are worth mid-gesture are skipped at
    /// this quality and applied as soon as the gesture ends.
    var appliesExpensiveStages: Bool { self != .interactive }

    /// Multiplier on blur radii and similar, to keep interactive frames cheap
    /// without changing what the user sees when they stop moving.
    var samplingScale: Double {
        switch self {
        case .interactive: 0.5
        case .preview: 1
        case .final: 1
        }
    }
}
