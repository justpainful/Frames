import SwiftUI

/// Direct manipulation of everything that floats over the media.
///
/// Text, image overlays, blur regions and selective adjustments are all moved
/// the same way: drag to move, pinch to scale, two fingers to rotate. Tapping
/// one selects it, which is what swaps the bottom strip for that object's
/// controls — the two halves of the contextual model meeting.
struct CanvasLayerHandles: View {
    let session: EditorSession
    let mediaFrame: CGRect
    let isEnabled: Bool

    @State private var dragOrigin: LayerTransform?
    @State private var gestureScale: Double = 1
    @State private var gestureRotation: Double = 0
    @State private var activeGuides: Set<Guide> = []

    private var document: EditDocument { session.document }
    private var time: TimeInterval { session.currentTime }

    enum Guide: Hashable {
        case horizontalCentre
        case verticalCentre
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleTextOverlays) { overlay in
                handle(
                    selection: .text(overlay.id),
                    transform: overlay.transform.evaluated(with: overlay.keyframes, at: time),
                    size: textSize(overlay),
                    label: overlay.string
                ) { transform, isFinal in
                    session.updateText(overlay.id, isFinal: isFinal) { $0.transform = transform }
                }
            }

            ForEach(visibleImageOverlays) { overlay in
                handle(
                    selection: .imageOverlay(overlay.id),
                    transform: overlay.transform.evaluated(with: overlay.keyframes, at: time),
                    size: overlaySize(overlay),
                    label: String(localized: "Image", comment: "Accessibility label")
                ) { transform, isFinal in
                    session.updateImageOverlay(overlay.id, isFinal: isFinal) { $0.transform = transform }
                }
            }

            ForEach(visibleBlurRegions) { region in
                if let mask = region.mask, mask.shape.isManipulable {
                    handle(
                        selection: .blur(region.id),
                        transform: mask.transform.evaluated(with: mask.keyframes, at: time),
                        size: CGSize(width: mask.size.width, height: mask.size.height),
                        label: region.displayName,
                        showsOutline: true
                    ) { transform, isFinal in
                        session.updateBlur(region.id, isFinal: isFinal) { $0.mask?.transform = transform }
                    }
                }
            }

            ForEach(document.selectiveAdjustments) { adjustment in
                if adjustment.mask.shape.isManipulable, isVisible(adjustment.timeRange) {
                    handle(
                        selection: .selectiveAdjustment(adjustment.id),
                        transform: adjustment.mask.transform.evaluated(
                            with: adjustment.mask.keyframes, at: time
                        ),
                        size: adjustment.mask.size,
                        label: String(localized: "Selective adjustment", comment: "Accessibility label"),
                        showsOutline: true
                    ) { transform, isFinal in
                        session.updateSelectiveAdjustment(adjustment.id, isFinal: isFinal) {
                            $0.mask.transform = transform
                        }
                    }
                }
            }

            ForEach(visibleShapes, id: \.shape.id) { entry in
                shapeHandles(drawingID: entry.drawingID, shape: entry.shape)
            }

            guideLines
        }
        .frame(width: mediaFrame.width, height: mediaFrame.height)
        .position(x: mediaFrame.midX, y: mediaFrame.midY)
        .allowsHitTesting(isEnabled)
    }

    // MARK: - Contents

    private var visibleTextOverlays: [TextOverlay] {
        document.textOverlays.filter { $0.isVisible(at: time) && !$0.isEmpty }
    }

    private var visibleImageOverlays: [ImageOverlay] {
        document.imageOverlays.filter { $0.isVisible(at: time) }
    }

    private var visibleBlurRegions: [BlurRegion] {
        document.blurRegions.filter { $0.isActive(at: time) }
    }

    private struct ShapeEntry {
        let drawingID: UUID
        let shape: VectorShape
    }

    private var visibleShapes: [ShapeEntry] {
        document.drawings
            .filter { $0.isVisible(at: time) }
            .flatMap { drawing in
                drawing.shapes.map { ShapeEntry(drawingID: drawing.id, shape: $0) }
            }
    }

    private func isVisible(_ range: TimeRange?) -> Bool {
        guard let range else { return true }
        return range.contains(time)
    }

    /// Text does not know its own rendered size on the main actor, so the
    /// handle is sized from the style — close enough for hit testing and for a
    /// selection outline.
    private func textSize(_ overlay: TextOverlay) -> CGSize {
        let lines = max(overlay.string.split(separator: "\n").count, 1)
        let longest = overlay.string
            .split(separator: "\n")
            .map(\.count)
            .max() ?? overlay.string.count
        let height = overlay.style.fontSize * Double(lines) * overlay.style.lineSpacing * 1.25
        let width = min(overlay.style.fontSize * Double(max(longest, 1)) * 0.58, overlay.maximumWidth)
        return CGSize(width: max(width, 0.08), height: max(height, 0.05))
    }

    private func overlaySize(_ overlay: ImageOverlay) -> CGSize {
        guard let asset = document.asset(id: overlay.assetID) else {
            return CGSize(width: 0.4, height: 0.4)
        }
        let aspect = asset.aspectRatio
        return aspect >= 1
            ? CGSize(width: 0.6, height: 0.6 / aspect)
            : CGSize(width: 0.6 * aspect, height: 0.6)
    }

    // MARK: - Handles

    @ViewBuilder
    private func handle(
        selection: EditorSelection,
        transform: LayerTransform,
        size: CGSize,
        label: String,
        showsOutline: Bool = false,
        apply: @escaping (LayerTransform, Bool) -> Void
    ) -> some View {
        let isSelected = session.selection == selection
        let width = max(size.width * transform.scale * mediaFrame.width, 34)
        let height = max(size.height * transform.scale * mediaFrame.height, 34)
        let centre = CGPoint(
            x: transform.position.x * mediaFrame.width,
            y: transform.position.y * mediaFrame.height
        )

        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: height)
            .overlay {
                if isSelected || showsOutline {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.white.opacity(0.7),
                            style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: isSelected ? [] : [5, 4])
                        )
                }
            }
            .rotationEffect(.radians(transform.rotation))
            .position(x: centre.x, y: centre.y)
            .contentShape(Rectangle())
            .onTapGesture { session.select(selection) }
            .gesture(dragGesture(selection: selection, transform: transform, apply: apply))
            .simultaneousGesture(scaleGesture(selection: selection, transform: transform, apply: apply))
            .simultaneousGesture(rotateGesture(selection: selection, transform: transform, apply: apply))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func dragGesture(
        selection: EditorSelection,
        transform: LayerTransform,
        apply: @escaping (LayerTransform, Bool) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = transform
                    session.select(selection)
                    Haptics.prepare()
                }
                guard let origin = dragOrigin else { return }

                var updated = origin
                updated.position.x = origin.position.x + value.translation.width / mediaFrame.width
                updated.position.y = origin.position.y + value.translation.height / mediaFrame.height

                // Snap to the centre lines. This is what makes "put the title in
                // the middle" a gesture rather than a fiddle.
                var guides: Set<Guide> = []
                let tolerance = 0.015
                if abs(updated.position.x - 0.5) < tolerance {
                    updated.position.x = 0.5
                    guides.insert(.verticalCentre)
                }
                if abs(updated.position.y - 0.5) < tolerance {
                    updated.position.y = 0.5
                    guides.insert(.horizontalCentre)
                }
                if guides != activeGuides {
                    if !guides.isEmpty { Haptics.snap() }
                    activeGuides = guides
                }

                updated.clampToUsableBounds()
                apply(updated, false)
            }
            .onEnded { _ in
                dragOrigin = nil
                activeGuides = []
                apply(currentTransform(for: selection) ?? transform, true)
            }
    }

    private func scaleGesture(
        selection: EditorSelection,
        transform: LayerTransform,
        apply: @escaping (LayerTransform, Bool) -> Void
    ) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = transform
                    session.select(selection)
                }
                guard let origin = dragOrigin else { return }
                var updated = origin
                updated.scale = origin.scale * value.magnification
                updated.clampToUsableBounds()
                gestureScale = value.magnification
                apply(updated, false)
            }
            .onEnded { _ in
                dragOrigin = nil
                gestureScale = 1
                apply(currentTransform(for: selection) ?? transform, true)
            }
    }

    private func rotateGesture(
        selection: EditorSelection,
        transform: LayerTransform,
        apply: @escaping (LayerTransform, Bool) -> Void
    ) -> some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(1))
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = transform
                    session.select(selection)
                    Haptics.prepare()
                }
                guard let origin = dragOrigin else { return }
                var updated = origin
                var angle = origin.rotation + value.rotation.radians

                // Detent every 45°, so straight and diagonal are easy to hit.
                let step = Double.pi / 4
                let nearest = (angle / step).rounded() * step
                if abs(angle - nearest) < 0.06 {
                    if abs(gestureRotation - nearest) > 0.001 {
                        gestureRotation = nearest
                        Haptics.snap()
                    }
                    angle = nearest
                }
                updated.rotation = angle
                apply(updated, false)
            }
            .onEnded { _ in
                dragOrigin = nil
                gestureRotation = 0
                apply(currentTransform(for: selection) ?? transform, true)
            }
    }

    /// Reads back the transform the document currently holds, so the final
    /// committed value is the one on screen rather than the gesture's start.
    private func currentTransform(for selection: EditorSelection) -> LayerTransform? {
        switch selection {
        case .text(let id):
            return document.textOverlays.first { $0.id == id }?.transform
        case .imageOverlay(let id):
            return document.imageOverlays.first { $0.id == id }?.transform
        case .blur(let id):
            return document.blurRegions.first { $0.id == id }?.mask?.transform
        case .selectiveAdjustment(let id):
            return document.selectiveAdjustments.first { $0.id == id }?.mask.transform
        default:
            return nil
        }
    }

    // MARK: - Shapes

    @ViewBuilder
    private func shapeHandles(drawingID: UUID, shape: VectorShape) -> some View {
        let start = CGPoint(x: shape.start.x * mediaFrame.width, y: shape.start.y * mediaFrame.height)
        let end = CGPoint(x: shape.end.x * mediaFrame.width, y: shape.end.y * mediaFrame.height)

        Group {
            endpoint(at: start) { location in
                session.updateDrawing(drawingID, isFinal: false) { drawing in
                    guard let index = drawing.shapes.firstIndex(where: { $0.id == shape.id }) else { return }
                    drawing.shapes[index].start = CGPoint(
                        x: location.x / mediaFrame.width,
                        y: location.y / mediaFrame.height
                    )
                }
            }
            endpoint(at: end) { location in
                session.updateDrawing(drawingID, isFinal: false) { drawing in
                    guard let index = drawing.shapes.firstIndex(where: { $0.id == shape.id }) else { return }
                    drawing.shapes[index].end = CGPoint(
                        x: location.x / mediaFrame.width,
                        y: location.y / mediaFrame.height
                    )
                }
            }
        }
    }

    private func endpoint(at point: CGPoint, move: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(Color.white)
            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
            .frame(width: 16, height: 16)
            .position(x: point.x, y: point.y)
            .contentShape(Circle().inset(by: -14))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in move(value.location) }
                    .onEnded { _ in
                        session.endInteraction()
                        Haptics.snap()
                    }
            )
            .accessibilityLabel(Text("Shape handle", comment: "Accessibility label"))
    }

    // MARK: - Guides

    @ViewBuilder
    private var guideLines: some View {
        if activeGuides.contains(.verticalCentre) {
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .position(x: mediaFrame.width / 2, y: mediaFrame.height / 2)
                .allowsHitTesting(false)
        }
        if activeGuides.contains(.horizontalCentre) {
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .position(x: mediaFrame.width / 2, y: mediaFrame.height / 2)
                .allowsHitTesting(false)
        }
    }
}
