import CoreImage
import MetalKit
import SwiftUI
import UIKit

/// Draws the processed camera frames.
///
/// Not `AVCaptureVideoPreviewLayer`: that shows the sensor's frames, and the
/// whole point of this mode is that the user is composing against the processed
/// picture. The frames arrive as `CIImage`s and are drawn straight to a Metal
/// drawable, which keeps the processing and the display in the same texture
/// without a round trip through a bitmap.
struct CameraPreviewView: UIViewRepresentable {
    let camera: CameraService

    func makeUIView(context: Context) -> CameraMetalView {
        let view = CameraMetalView()
        camera.onFrame = { [weak view] image in
            view?.enqueue(image)
        }
        return view
    }

    func updateUIView(_ view: CameraMetalView, context: Context) {}

    static func dismantleUIView(_ view: CameraMetalView, coordinator: ()) {
        view.enqueue(nil)
    }
}

/// The Metal surface the preview is drawn on.
final class CameraMetalView: MTKView {
    private let commandQueue: MTLCommandQueue?
    private let renderContext: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private let lock = NSLock()
    private var pending: CIImage?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        // The app's existing preview context, not a second one. Every CIContext
        // owns a texture cache and a compiled-kernel cache, and building a
        // parallel set of both for the viewfinder was pure duplicated memory
        // and duplicated shader compilation on the first few frames.
        renderContext = RenderContext.shared.preview

        super.init(frame: .zero, device: device)

        // Core Image needs to write into the drawable, which it cannot do if
        // the drawable is framebuffer-only.
        framebufferOnly = false
        // Driven by arriving frames rather than by a display link, so the view
        // does no work between them.
        isPaused = true
        enableSetNeedsDisplay = true
        backgroundColor = .black
        contentMode = .scaleAspectFill
        isOpaque = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("CameraMetalView is created in code")
    }

    /// Called from the capture queue. Only the most recent frame is kept: if the
    /// display falls behind, showing the newest frame is right and showing a
    /// queue of stale ones is not.
    func enqueue(_ image: CIImage?) {
        lock.lock()
        pending = image
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        lock.lock()
        let image = pending
        lock.unlock()

        guard let image,
              let drawable = currentDrawable,
              let commandQueue,
              let buffer = commandQueue.makeCommandBuffer()
        else { return }

        let target = CGRect(
            x: 0,
            y: 0,
            width: drawable.texture.width,
            height: drawable.texture.height
        )
        guard target.width > 0, target.height > 0, image.extent.isRenderable else { return }

        // Fill: the preview is full-bleed, and letterboxing a viewfinder makes
        // it harder to judge the frame you are actually going to get.
        let scale = max(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = scaled.transformed(by: CGAffineTransform(
            translationX: (target.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (target.height - scaled.extent.height) / 2 - scaled.extent.minY
        ))

        renderContext.render(
            centred,
            to: drawable.texture,
            commandBuffer: buffer,
            bounds: target,
            colorSpace: colorSpace
        )
        buffer.present(drawable)
        buffer.commit()
    }
}
