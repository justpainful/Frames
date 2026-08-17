import SwiftUI

/// Drawing a freeform mask.
///
/// The other mask shapes are dragged into place; this one is traced. It exists
/// because a rectangle and an ellipse cannot cover a licence plate on an angle
/// or a shape that wraps around something, and asking someone to approximate
/// that with four rounded rectangles is not an answer.
///
/// The trace is simplified as it is captured: a finger produces far more points
/// than a mask edge needs, and keeping all of them would bloat the session file
/// and slow every frame that rasterises the shape.
struct FreeformMaskOverlay: View {
    let session: EditorSession
    let regionID: UUID
    let mediaFrame: CGRect
    let onFinished: () -> Void

    @State private var points: [CGPoint] = []
    @State private var isDrawing = false

    /// Minimum distance between kept points, as a fraction of the frame. Below
    /// this the extra points describe the finger, not the shape.
    private let minimumSpacing: CGFloat = 0.012

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())

            if points.count > 1 {
                tracePath
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                tracePath
                    .fill(Color.accentColor.opacity(0.18))
            }

            if points.isEmpty {
                Text("Trace the area with one finger.", comment: "Freeform mask prompt")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .position(x: mediaFrame.width / 2, y: mediaFrame.height / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: mediaFrame.width, height: mediaFrame.height)
        .position(x: mediaFrame.midX, y: mediaFrame.midY)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDrawing {
                        isDrawing = true
                        points = []
                        Haptics.prepare()
                    }
                    append(value.location)
                }
                .onEnded { _ in
                    isDrawing = false
                    commit()
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Freeform mask", comment: "Accessibility label"))
        .accessibilityHint(Text("Trace the area with one finger.", comment: "Accessibility hint"))
    }

    private var tracePath: Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.x * mediaFrame.width, y: first.y * mediaFrame.height))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * mediaFrame.width, y: point.y * mediaFrame.height))
            }
            path.closeSubpath()
        }
    }

    private func append(_ location: CGPoint) {
        let normalized = CGPoint(
            x: min(max(location.x / max(mediaFrame.width, 1), 0), 1),
            y: min(max(location.y / max(mediaFrame.height, 1), 0), 1)
        )
        guard let last = points.last else {
            points.append(normalized)
            return
        }
        guard hypot(normalized.x - last.x, normalized.y - last.y) >= minimumSpacing else { return }
        points.append(normalized)
    }

    private func commit() {
        // Three points is the minimum that encloses anything; below that the
        // trace was a tap and the mask is left as it was.
        guard points.count >= 3 else {
            points = []
            Haptics.failure()
            return
        }

        let traced = points
        session.updateBlur(regionID) { region in
            region.mask?.shape = .freeform(points: traced)
            // The bounding box becomes the mask's transform so the shape can
            // still be moved and scaled afterwards like any other.
            let minX = traced.map(\.x).min() ?? 0
            let maxX = traced.map(\.x).max() ?? 1
            let minY = traced.map(\.y).min() ?? 0
            let maxY = traced.map(\.y).max() ?? 1
            region.mask?.transform.position = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            region.mask?.size = CGSize(width: max(maxX - minX, 0.02), height: max(maxY - minY, 0.02))
        }
        Haptics.success()
        onFinished()
    }
}
