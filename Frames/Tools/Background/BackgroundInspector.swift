import SwiftUI

/// The Background tool.
///
/// Called Background rather than Canvas, because "what fills the space around
/// my video" is the question people actually have when they turn a horizontal
/// clip into a vertical one.
struct BackgroundInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    private var background: BackgroundStyle { session.document.background }

    var body: some View {
        InspectorSurface(title: String(localized: "Background", comment: "Tool title"), onDone: onDone) {
            VStack(spacing: 12) {
                SegmentedChoice(
                    values: BackgroundStyle.Fill.allCases,
                    selection: Binding(
                        get: { background.fill },
                        set: { value in
                            var updated = background
                            updated.fill = value
                            session.setBackground(updated)
                        }
                    ),
                    label: { $0.displayName },
                    symbol: { $0.symbolName }
                )

                switch background.fill {
                case .color:
                    ColorSwatchRow(color: Binding(
                        get: { background.color },
                        set: { value in
                            var updated = background
                            updated.color = value
                            session.setBackground(updated)
                        }
                    ))
                case .blur:
                    ParameterSlider(
                        title: String(localized: "Blur", comment: "Background control"),
                        value: Binding(
                            get: { background.blurAmount },
                            set: { value in
                                var updated = background
                                updated.blurAmount = value
                                session.setBackground(updated, isFinal: false)
                            }
                        ),
                        range: 0...1,
                        neutral: nil,
                        format: { "\(Int(($0 * 100).rounded()))" }
                    ) { editing in
                        if !editing { session.endInteraction() }
                    }
                case .fit, .fill, .image:
                    EmptyView()
                }

                ParameterSlider(
                    title: String(localized: "Content Size", comment: "Background control"),
                    value: Binding(
                        get: { background.contentScale },
                        set: { value in
                            var updated = background
                            updated.contentScale = value
                            session.setBackground(updated, isFinal: false)
                        }
                    ),
                    range: 0.3...1.6,
                    neutral: 1,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                ) { editing in
                    if !editing { session.endInteraction() }
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(AspectPreset.allCases) { preset in
                            Button {
                                session.setOutputAspect(preset)
                            } label: {
                                Text(preset.displayName)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background {
                                Capsule().fill(
                                    session.document.outputAspect == preset
                                        ? Color.accentColor
                                        : Color(.tertiarySystemFill)
                                )
                            }
                            .foregroundStyle(
                                session.document.outputAspect == preset ? Color.white : Color.primary
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)

                Toggle(isOn: Binding(
                    get: { session.document.safeAreaGuides.isEnabled },
                    set: { session.setSafeAreaGuides(enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Safe Area Guides", comment: "Background option")
                            .font(.subheadline)
                        Text("Shows where captions and controls usually sit.",
                             comment: "Background option detail")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}
