import SwiftUI

/// The crop rectangle drawn over the canvas.
///
/// Eight handles plus the body of the rect, with a rule-of-thirds grid that
/// appears while dragging. Everything is in normalized crop space, so the same
/// numbers work at preview size and at export size.
struct CropOverlayView: View {
    @Binding var crop: CropState
    /// The rect the media actually occupies on screen.
    let mediaFrame: CGRect
    /// Aspect ratio the crop is constrained to, if any.
    let constrainedAspect: CGFloat?
    let onCommit: () -> Void

    @State private var isDragging = false
    @State private var dragOrigin: CGRect?

    private let handleLength: CGFloat = 22
    private let handleThickness: CGFloat = 3
    private let minimumSize: CGFloat = 0.06

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimming
            frame
            if isDragging { grid }
            handles
        }
        .frame(width: mediaFrame.width, height: mediaFrame.height)
        .position(x: mediaFrame.midX, y: mediaFrame.midY)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Crop rectangle", comment: "Accessibility label"))
        .accessibilityHint(Text("Drag the edges to change the crop.", comment: "Accessibility hint"))
    }

    private var rectInView: CGRect {
        CGRect(
            x: crop.rect.minX * mediaFrame.width,
            y: crop.rect.minY * mediaFrame.height,
            width: crop.rect.width * mediaFrame.width,
            height: crop.rect.height * mediaFrame.height
        )
    }

    // MARK: - Pieces

    private var dimming: some View {
        Rectangle()
            .fill(Color.black.opacity(isDragging ? 0.5 : 0.35))
            .reverseMask {
                Rectangle()
                    .frame(width: rectInView.width, height: rectInView.height)
                    .position(x: rectInView.midX, y: rectInView.midY)
            }
            .allowsHitTesting(false)
    }

    private var frame: some View {
        Rectangle()
            .strokeBorder(Color.white, lineWidth: 1)
            .frame(width: rectInView.width, height: rectInView.height)
            .position(x: rectInView.midX, y: rectInView.midY)
            .contentShape(Rectangle())
            .gesture(bodyDrag)
    }

    private var grid: some View {
        Path { path in
            for index in 1...2 {
                let fraction = CGFloat(index) / 3
                let x = rectInView.minX + rectInView.width * fraction
                path.move(to: CGPoint(x: x, y: rectInView.minY))
                path.addLine(to: CGPoint(x: x, y: rectInView.maxY))
                let y = rectInView.minY + rectInView.height * fraction
                path.move(to: CGPoint(x: rectInView.minX, y: y))
                path.addLine(to: CGPoint(x: rectInView.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    private var handles: some View {
        ForEach(Corner.allCases, id: \.self) { corner in
            cornerHandle(corner)
        }
    }

    private func cornerHandle(_ corner: Corner) -> some View {
        let rect = rectInView
        let point = corner.point(in: rect)

        return ZStack {
            Rectangle()
                .fill(Color.white)
                .frame(width: handleLength, height: handleThickness)
                .offset(x: corner.horizontalOffset * (handleLength - handleThickness) / 2)
            Rectangle()
                .fill(Color.white)
                .frame(width: handleThickness, height: handleLength)
                .offset(y: corner.verticalOffset * (handleLength - handleThickness) / 2)
        }
        .position(x: point.x, y: point.y)
        .contentShape(Rectangle().inset(by: -18))
        .gesture(cornerDrag(corner))
        .accessibilityLabel(corner.accessibilityName)
    }

    // MARK: - Gestures

    private var bodyDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = crop.rect
                    isDragging = true
                    Haptics.prepare()
                }
                guard let origin = dragOrigin else { return }
                let dx = value.translation.width / mediaFrame.width
                let dy = value.translation.height / mediaFrame.height
                var moved = origin
                moved.origin.x = min(max(origin.minX + dx, 0), 1 - origin.width)
                moved.origin.y = min(max(origin.minY + dy, 0), 1 - origin.height)
                crop.rect = moved
            }
            .onEnded { _ in
                dragOrigin = nil
                isDragging = false
                onCommit()
            }
    }

    private func cornerDrag(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = crop.rect
                    isDragging = true
                    Haptics.prepare()
                }
                guard let origin = dragOrigin else { return }
                let dx = value.translation.width / mediaFrame.width
                let dy = value.translation.height / mediaFrame.height
                crop.rect = resized(origin, corner: corner, dx: dx, dy: dy)
            }
            .onEnded { _ in
                dragOrigin = nil
                isDragging = false
                onCommit()
                Haptics.snap()
            }
    }

    /// Moves one corner, keeping the opposite one anchored and honouring the
    /// aspect constraint if there is one.
    private func resized(_ origin: CGRect, corner: Corner, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = origin.minX
        var minY = origin.minY
        var maxX = origin.maxX
        var maxY = origin.maxY

        if corner.movesLeadingEdge { minX += dx } else { maxX += dx }
        if corner.movesTopEdge { minY += dy } else { maxY += dy }

        minX = min(max(minX, 0), 1)
        minY = min(max(minY, 0), 1)
        maxX = min(max(maxX, 0), 1)
        maxY = min(max(maxY, 0), 1)

        var width = max(maxX - minX, minimumSize)
        var height = max(maxY - minY, minimumSize)

        if let aspect = constrainedAspect, aspect > 0 {
            // Adjust the dimension the drag moved least, so the corner tracks
            // the finger on its dominant axis.
            let targetHeight = width / aspect
            if abs(dx) >= abs(dy) {
                height = targetHeight
            } else {
                width = height * aspect
            }
        }

        if corner.movesLeadingEdge { minX = maxX - width } else { maxX = minX + width }
        if corner.movesTopEdge { minY = maxY - height } else { maxY = minY + height }

        // Re-clamp after the aspect correction so the rect stays inside the
        // frame rather than sliding off it.
        if minX < 0 { maxX -= minX; minX = 0 }
        if minY < 0 { maxY -= minY; minY = 0 }
        if maxX > 1 { minX -= maxX - 1; maxX = 1 }
        if maxY > 1 { minY -= maxY - 1; maxY = 1 }

        return CGRect(
            x: min(max(minX, 0), 1),
            y: min(max(minY, 0), 1),
            width: min(max(maxX - minX, minimumSize), 1),
            height: min(max(maxY - minY, minimumSize), 1)
        )
    }

    // MARK: - Corners

    private enum Corner: CaseIterable, Hashable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var movesLeadingEdge: Bool { self == .topLeading || self == .bottomLeading }
        var movesTopEdge: Bool { self == .topLeading || self == .topTrailing }

        var horizontalOffset: CGFloat { movesLeadingEdge ? 1 : -1 }
        var verticalOffset: CGFloat { movesTopEdge ? 1 : -1 }

        func point(in rect: CGRect) -> CGPoint {
            CGPoint(
                x: movesLeadingEdge ? rect.minX : rect.maxX,
                y: movesTopEdge ? rect.minY : rect.maxY
            )
        }

        var accessibilityName: String {
            switch self {
            case .topLeading: String(localized: "Top left handle", comment: "Accessibility label")
            case .topTrailing: String(localized: "Top right handle", comment: "Accessibility label")
            case .bottomLeading: String(localized: "Bottom left handle", comment: "Accessibility label")
            case .bottomTrailing: String(localized: "Bottom right handle", comment: "Accessibility label")
            }
        }
    }
}

extension View {
    /// Punches a hole in a view, used for the crop dimming.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
