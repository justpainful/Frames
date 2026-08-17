import SwiftUI

/// The Text tool.
///
/// Tapping Text creates a layer and puts the keyboard up straight away — there
/// is no "add text layer" step in between. Everything after that is styling the
/// layer that is already on screen.
struct TextInspector: View {
    let session: EditorSession
    let focus: EditorDetail
    let onDone: () -> Void

    @FocusState private var isEditing: Bool
    @State private var draft: String = ""

    private var overlay: TextOverlay? {
        guard case .text(let id) = session.selection else { return nil }
        return session.document.textOverlays.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Text", comment: "Tool title"), onDone: {
            if let overlay { session.discardEmptyText(overlay.id) }
            onDone()
        }) {
            if let overlay {
                content(for: overlay)
            } else {
                Button {
                    _ = session.addText()
                } label: {
                    Label {
                        Text("Add Text", comment: "Text action")
                    } icon: {
                        Image(systemName: "textformat")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .onAppear {
            if session.selection.isNone, session.document.textOverlays.isEmpty {
                let id = session.addText()
                draft = ""
                _ = id
                isEditing = true
            } else if let overlay {
                draft = overlay.string
                if overlay.isEmpty { isEditing = true }
            }
        }
    }

    @ViewBuilder
    private func content(for overlay: TextOverlay) -> some View {
        VStack(spacing: 12) {
            switch focus {
            case .font:
                fontControls(overlay)
            case .textStyle:
                styleControls(overlay)
            case .textColor:
                colourControls(overlay)
            case .textAlignment:
                alignmentControls(overlay)
            case .textAnimation:
                animationControls(overlay)
            default:
                editorField(overlay)
            }
        }
    }

    private func editorField(_ overlay: TextOverlay) -> some View {
        VStack(spacing: 10) {
            TextField(
                String(localized: "Type something", comment: "Text field placeholder"),
                text: Binding(
                    get: { draft },
                    set: { value in
                        draft = value
                        session.updateText(overlay.id, isFinal: false) { $0.string = value }
                    }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...4)
            .focused($isEditing)
            .padding(10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onSubmit { session.endInteraction() }
            // Arabic and English both lay out correctly because nothing here
            // forces a direction: the field and the renderer both use the
            // natural direction of the text itself.
            .multilineTextAlignment(.leading)

            ParameterSlider(
                title: String(localized: "Size", comment: "Text control"),
                value: Binding(
                    get: { overlay.style.fontSize },
                    set: { value in
                        session.updateText(overlay.id, isFinal: false) { $0.style.fontSize = value }
                    }
                ),
                range: 0.02...0.3,
                neutral: nil,
                format: { "\(Int(($0 * 1000).rounded()))" }
            ) { editing in
                if !editing { session.endInteraction() }
            }
        }
    }

    private func fontControls(_ overlay: TextOverlay) -> some View {
        VStack(spacing: 10) {
            SegmentedChoice(
                values: TextFontDesign.allCases,
                selection: Binding(
                    get: { overlay.style.design },
                    set: { value in session.updateText(overlay.id) { $0.style.design = value } }
                ),
                label: { $0.displayName }
            )
            SegmentedChoice(
                values: TextWeight.allCases,
                selection: Binding(
                    get: { overlay.style.weight },
                    set: { value in session.updateText(overlay.id) { $0.style.weight = value } }
                ),
                label: { $0.displayName }
            )
            ParameterSlider(
                title: String(localized: "Size", comment: "Text control"),
                value: Binding(
                    get: { overlay.style.fontSize },
                    set: { value in
                        session.updateText(overlay.id, isFinal: false) { $0.style.fontSize = value }
                    }
                ),
                range: 0.02...0.3,
                neutral: nil,
                format: { "\(Int(($0 * 1000).rounded()))" }
            ) { editing in
                if !editing { session.endInteraction() }
            }
        }
    }

    private func styleControls(_ overlay: TextOverlay) -> some View {
        VStack(spacing: 10) {
            SegmentedChoice(
                values: TextBackgroundStyle.Shape.allCases,
                selection: Binding(
                    get: { overlay.style.background.shape },
                    set: { value in session.updateText(overlay.id) { $0.style.background.shape = value } }
                ),
                label: { $0.displayName }
            )

            Toggle(isOn: Binding(
                get: { overlay.style.shadow.isEnabled },
                set: { value in session.updateText(overlay.id) { $0.style.shadow.isEnabled = value } }
            )) {
                Text("Shadow", comment: "Text control").font(.subheadline)
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { overlay.style.stroke.isEnabled },
                set: { value in session.updateText(overlay.id) { $0.style.stroke.isEnabled = value } }
            )) {
                Text("Outline", comment: "Text control").font(.subheadline)
            }
            .toggleStyle(.switch)

            ParameterSlider(
                title: String(localized: "Opacity", comment: "Text control"),
                value: Binding(
                    get: { overlay.transform.opacity },
                    set: { value in
                        session.updateText(overlay.id, isFinal: false) { $0.transform.opacity = value }
                    }
                ),
                range: 0...1,
                neutral: nil,
                format: { "\(Int(($0 * 100).rounded()))" }
            ) { editing in
                if !editing { session.endInteraction() }
            }
        }
    }

    private func colourControls(_ overlay: TextOverlay) -> some View {
        VStack(spacing: 10) {
            Text("Text", comment: "Text control")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ColorSwatchRow(color: Binding(
                get: { overlay.style.color },
                set: { value in session.updateText(overlay.id) { $0.style.color = value } }
            ))

            if overlay.style.background.shape != .none {
                Text("Background", comment: "Text control")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ColorSwatchRow(color: Binding(
                    get: { overlay.style.background.color },
                    set: { value in session.updateText(overlay.id) { $0.style.background.color = value } }
                ))
            }
        }
    }

    private func alignmentControls(_ overlay: TextOverlay) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(TextAlignmentChoice.allCases) { choice in
                    Button {
                        session.updateText(overlay.id) { $0.style.alignment = choice }
                    } label: {
                        Image(systemName: choice.symbolName)
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(overlay.style.alignment == choice
                                  ? Color.accentColor
                                  : Color(.tertiarySystemFill))
                    }
                    .foregroundStyle(overlay.style.alignment == choice ? Color.white : Color.primary)
                    .accessibilityAddTraits(
                        overlay.style.alignment == choice ? [.isSelected, .isButton] : .isButton
                    )
                }
            }

            ParameterSlider(
                title: String(localized: "Tracking", comment: "Text control"),
                value: Binding(
                    get: { overlay.style.tracking },
                    set: { value in
                        session.updateText(overlay.id, isFinal: false) { $0.style.tracking = value }
                    }
                ),
                range: -0.1...0.4,
                neutral: 0,
                format: { String(format: "%.2f", $0) }
            ) { editing in
                if !editing { session.endInteraction() }
            }

            ParameterSlider(
                title: String(localized: "Line Spacing", comment: "Text control"),
                value: Binding(
                    get: { overlay.style.lineSpacing },
                    set: { value in
                        session.updateText(overlay.id, isFinal: false) { $0.style.lineSpacing = value }
                    }
                ),
                range: 0.7...2,
                neutral: 1.1,
                format: { String(format: "%.2f", $0) }
            ) { editing in
                if !editing { session.endInteraction() }
            }
        }
    }

    private func animationControls(_ overlay: TextOverlay) -> some View {
        VStack(spacing: 10) {
            Text("In", comment: "Animation phase")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            SegmentedChoice(
                values: TextAnimationIn.allCases,
                selection: Binding(
                    get: { overlay.animation.entrance },
                    set: { value in session.updateText(overlay.id) { $0.animation.entrance = value } }
                ),
                label: { $0.displayName }
            )

            Text("Loop", comment: "Animation phase")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            SegmentedChoice(
                values: TextAnimationLoop.allCases,
                selection: Binding(
                    get: { overlay.animation.loop },
                    set: { value in session.updateText(overlay.id) { $0.animation.loop = value } }
                ),
                label: { $0.displayName }
            )

            Text("Out", comment: "Animation phase")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            SegmentedChoice(
                values: TextAnimationOut.allCases,
                selection: Binding(
                    get: { overlay.animation.exit },
                    set: { value in session.updateText(overlay.id) { $0.animation.exit = value } }
                ),
                label: { $0.displayName }
            )
        }
    }
}
