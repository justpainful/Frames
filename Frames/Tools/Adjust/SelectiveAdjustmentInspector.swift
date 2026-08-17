import SwiftUI

/// Adjustments restricted to a mask.
///
/// The same eighteen parameters as the Adjust tool, applied through a shape the
/// user positions on the canvas — brighten a face, pull down a sky, desaturate
/// a background. It is a separate inspector from Adjust because the values go
/// somewhere else: into this adjustment's own set, not the document's grade.
struct SelectiveAdjustmentInspector: View {
    let session: EditorSession
    let focus: EditorDetail
    let onDone: () -> Void

    @State private var group: AdjustmentGroup = .light
    @State private var parameter: AdjustmentParameter = .exposure

    private var adjustment: SelectiveAdjustment? {
        guard case .selectiveAdjustment(let id) = session.selection else { return nil }
        return session.document.selectiveAdjustments.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(
            title: String(localized: "Selective Adjustment", comment: "Tool title"),
            onDone: onDone
        ) {
            if let adjustment {
                if focus == .blurMask {
                    maskControls(adjustment)
                } else {
                    adjustControls(adjustment)
                }
            } else {
                Button {
                    _ = session.addSelectiveAdjustment()
                } label: {
                    Label {
                        Text("Add Selective Adjustment", comment: "Selective action")
                    } icon: {
                        Image(systemName: "circle.dashed.inset.filled")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private func adjustControls(_ adjustment: SelectiveAdjustment) -> some View {
        VStack(spacing: 12) {
            ParameterSlider(
                title: parameter.displayName,
                value: Binding(
                    get: { adjustment.adjustments[parameter] },
                    set: { value in
                        session.updateSelectiveAdjustment(adjustment.id, isFinal: false) {
                            $0.adjustments[parameter] = value
                        }
                    }
                ),
                range: parameter.range,
                neutral: parameter.defaultValue,
                format: { parameter.formattedValue($0) }
            ) { editing in
                if !editing { session.endInteraction() }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(group.parameters) { option in
                        Button {
                            parameter = option
                            Haptics.snap()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: option.symbolName)
                                    .font(.system(size: 14))
                                    .frame(width: 34, height: 34)
                                    .background(
                                        Circle().fill(
                                            adjustment.adjustments.isActive(option)
                                                ? Color.accentColor.opacity(0.18)
                                                : Color.clear
                                        )
                                    )
                                Text(option.displayName)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                            }
                            .frame(width: 62)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(parameter == option ? Color.accentColor : Color.primary)
                        .onTapGesture(count: 2) {
                            session.updateSelectiveAdjustment(adjustment.id) {
                                $0.adjustments.reset(option)
                            }
                        }
                        .accessibilityLabel(option.displayName)
                        .accessibilityValue(option.formattedValue(adjustment.adjustments[option]))
                        .accessibilityAddTraits(parameter == option ? [.isSelected, .isButton] : .isButton)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                SegmentedChoice(
                    values: AdjustmentGroup.allCases,
                    selection: Binding(
                        get: { group },
                        set: { newGroup in
                            group = newGroup
                            parameter = newGroup.parameters[0]
                        }
                    ),
                    label: { $0.displayName }
                )

                Spacer(minLength: 0)

                Button {
                    session.updateSelectiveAdjustment(adjustment.id) { $0.adjustments.resetAll() }
                    Haptics.edit()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.glass)
                .disabled(adjustment.adjustments.isIdentity)
                .accessibilityLabel(Text("Reset All", comment: "Adjust action"))
            }
        }
    }

    private func maskControls(_ adjustment: SelectiveAdjustment) -> some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.shapes, id: \.label) { option in
                        Button {
                            session.updateSelectiveAdjustment(adjustment.id) { $0.mask.shape = option.shape }
                            Haptics.snap()
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: option.shape.symbolName)
                                    .font(.system(size: 16))
                                    .frame(width: 42, height: 42)
                                    .background(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(matches(adjustment.mask.shape, option.shape)
                                                  ? Color.accentColor
                                                  : Color(.tertiarySystemFill))
                                    )
                                    .foregroundStyle(matches(adjustment.mask.shape, option.shape)
                                                     ? Color.white : Color.primary)
                                Text(option.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 58)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.label)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)

            ParameterSlider(
                title: String(localized: "Feather", comment: "Mask control"),
                value: Binding(
                    get: { adjustment.mask.feather },
                    set: { value in
                        session.updateSelectiveAdjustment(adjustment.id, isFinal: false) {
                            $0.mask.feather = value
                        }
                    }
                ),
                range: 0...1,
                neutral: nil,
                format: { "\(Int(($0 * 100).rounded()))" }
            ) { editing in
                if !editing { session.endInteraction() }
            }

            Toggle(isOn: Binding(
                get: { adjustment.mask.isInverted },
                set: { value in
                    session.updateSelectiveAdjustment(adjustment.id) { $0.mask.isInverted = value }
                }
            )) {
                Text("Invert", comment: "Mask option").font(.subheadline)
            }
            .toggleStyle(.switch)
        }
    }

    private static let shapes: [(label: String, shape: MaskShape)] = [
        (String(localized: "Rounded", comment: "Mask shape"), .roundedRectangle(cornerRadius: 0.08)),
        (String(localized: "Ellipse", comment: "Mask shape"), .ellipse),
        (String(localized: "Rectangle", comment: "Mask shape"), .rectangle),
        (String(localized: "Linear", comment: "Mask shape"), .linearGradient(angle: 0)),
        (String(localized: "Radial", comment: "Mask shape"), .radialGradient),
        (String(localized: "Subject", comment: "Mask shape"), .foregroundSubject)
    ]

    private func matches(_ lhs: MaskShape, _ rhs: MaskShape) -> Bool {
        switch (lhs, rhs) {
        case (.rectangle, .rectangle),
             (.roundedRectangle, .roundedRectangle),
             (.ellipse, .ellipse),
             (.linearGradient, .linearGradient),
             (.radialGradient, .radialGradient),
             (.foregroundSubject, .foregroundSubject),
             (.freeform, .freeform):
            true
        default:
            false
        }
    }
}
