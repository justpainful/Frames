import PencilKit
import SwiftUI

/// Drawing controls: PencilKit's own tool picker for freehand, plus Frames'
/// shape tools, which PencilKit does not provide.
struct DrawInspector: View {
    let session: EditorSession
    let focus: EditorDetail
    let onDone: () -> Void

    @State private var shapeKind: VectorShape.Kind = .arrow
    @State private var shapeColor: RGBAColor = RGBAColor(red: 1, green: 0.27, blue: 0.23)
    @State private var lineWidth: Double = 0.008
    @State private var isFilled = false

    private var drawing: DrawingOverlay? {
        guard case .drawing(let id) = session.selection else { return nil }
        return session.document.drawings.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Draw", comment: "Tool title"), onDone: {
            if let drawing { session.discardEmptyDrawing(drawing.id) }
            onDone()
        }) {
            if let drawing {
                switch focus {
                case .shapes:
                    shapeControls(drawing)
                case .overlayOpacity:
                    opacityControls(drawing)
                default:
                    freehandControls(drawing)
                }
            } else {
                Button {
                    _ = session.addDrawing()
                } label: {
                    Label {
                        Text("Start Drawing", comment: "Drawing action")
                    } icon: {
                        Image(systemName: "pencil.tip")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private func freehandControls(_ drawing: DrawingOverlay) -> some View {
        VStack(spacing: 10) {
            Text("Draw directly on the media. The pen, marker and eraser are in the tool palette.",
                 comment: "Drawing explanation")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button {
                    session.updateDrawing(drawing.id) { $0.pencilData = Data() }
                    Haptics.edit()
                } label: {
                    Label {
                        Text("Clear Strokes", comment: "Drawing action")
                    } icon: {
                        Image(systemName: "eraser")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .disabled(drawing.pencilData.isEmpty)

                Button {
                    session.updateDrawing(drawing.id) { $0.shapes.removeAll() }
                    Haptics.edit()
                } label: {
                    Label {
                        Text("Clear Shapes", comment: "Drawing action")
                    } icon: {
                        Image(systemName: "square.on.circle")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .disabled(drawing.shapes.isEmpty)
            }
        }
    }

    private func shapeControls(_ drawing: DrawingOverlay) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(VectorShape.Kind.allCases) { kind in
                    Button {
                        shapeKind = kind
                        Haptics.snap()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.symbolName)
                                .font(.system(size: 16))
                            Text(kind.displayName)
                                .font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(shapeKind == kind ? Color.accentColor : Color(.tertiarySystemFill))
                    }
                    .foregroundStyle(shapeKind == kind ? Color.white : Color.primary)
                    .accessibilityAddTraits(shapeKind == kind ? [.isSelected, .isButton] : .isButton)
                }
            }

            ColorSwatchRow(color: $shapeColor)

            ParameterSlider(
                title: String(localized: "Line Width", comment: "Shape control"),
                value: $lineWidth,
                range: 0.002...0.04,
                neutral: nil,
                format: { "\(Int(($0 * 1000).rounded()))" }
            )

            if shapeKind == .rectangle || shapeKind == .ellipse {
                Toggle(isOn: $isFilled) {
                    Text("Filled", comment: "Shape control").font(.subheadline)
                }
                .toggleStyle(.switch)
            }

            Button {
                addShape(to: drawing)
            } label: {
                Label {
                    Text("Add Shape", comment: "Shape action")
                } icon: {
                    Image(systemName: "plus")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func opacityControls(_ drawing: DrawingOverlay) -> some View {
        ParameterSlider(
            title: String(localized: "Opacity", comment: "Drawing control"),
            value: Binding(
                get: { drawing.opacity },
                set: { value in
                    session.updateDrawing(drawing.id, isFinal: false) { $0.opacity = value }
                }
            ),
            range: 0...1,
            neutral: nil,
            format: { "\(Int(($0 * 100).rounded()))" }
        ) { editing in
            if !editing { session.endInteraction() }
        }
    }

    /// New shapes land in the middle of the frame at a usable size; the user
    /// then drags their endpoints on the canvas.
    private func addShape(to drawing: DrawingOverlay) {
        let shape = VectorShape(
            kind: shapeKind,
            start: CGPoint(x: 0.32, y: 0.44),
            end: CGPoint(x: 0.68, y: 0.60),
            color: shapeColor,
            lineWidth: lineWidth,
            isFilled: isFilled
        )
        session.updateDrawing(drawing.id) { $0.shapes.append(shape) }
        Haptics.edit()
    }
}

/// PencilKit's canvas, bridged so freehand drawing behaves exactly as it does
/// in the system apps — including the eraser, the lasso and Apple Pencil.
struct DrawingCanvasView: UIViewRepresentable {
    @Binding var data: Data
    let isActive: Bool
    let onChange: (Data) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.delegate = context.coordinator
        if let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }
        context.coordinator.attachToolPicker(to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        canvas.isUserInteractionEnabled = isActive

        // Only push data back into the canvas when it genuinely differs, or an
        // undo would fight the user's next stroke.
        if canvas.drawing.dataRepresentation() != data,
           let drawing = try? PKDrawing(data: data) {
            context.coordinator.isApplyingExternalChange = true
            canvas.drawing = drawing
            context.coordinator.isApplyingExternalChange = false
        }

        context.coordinator.setToolPickerVisible(isActive, on: canvas)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (Data) -> Void
        var isApplyingExternalChange = false
        private let toolPicker = PKToolPicker()

        init(onChange: @escaping (Data) -> Void) {
            self.onChange = onChange
        }

        func attachToolPicker(to canvas: PKCanvasView) {
            toolPicker.addObserver(canvas)
        }

        func setToolPickerVisible(_ visible: Bool, on canvas: PKCanvasView) {
            toolPicker.setVisible(visible, forFirstResponder: canvas)
            if visible, !canvas.isFirstResponder {
                canvas.becomeFirstResponder()
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalChange else { return }
            onChange(canvasView.drawing.dataRepresentation())
        }
    }
}
