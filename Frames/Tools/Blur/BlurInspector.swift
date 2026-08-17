import SwiftUI

/// The Blur tool.
///
/// The first choice is what to blur, and that choice decides everything after
/// it. Picking Face runs detection and lets the user tap a face; picking Area
/// puts a shape on the canvas; picking Background segments the subject. One
/// engine, six front doors.
struct BlurInspector: View {
    let session: EditorSession
    let focus: EditorDetail
    let onDone: () -> Void

    private var region: BlurRegion? {
        guard case .blur(let id) = session.selection else { return nil }
        return session.document.blurRegions.first { $0.id == id }
    }

    var body: some View {
        InspectorSurface(title: title, onDone: onDone) {
            if let region {
                controls(for: region)
            } else {
                scopePicker
            }
        }
    }

    private var title: String {
        region?.displayName ?? String(localized: "Blur", comment: "Tool title")
    }

    private var scopePicker: some View {
        VStack(spacing: 10) {
            Text("Choose what to blur.", comment: "Blur prompt")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(availableScopes) { scope in
                        Button {
                            session.addBlur(scope: scope)
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: scope.symbolName)
                                    .font(.system(size: 18))
                                    .frame(width: 46, height: 46)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color(.tertiarySystemFill))
                                    )
                                Text(scope.displayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 62)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(scope.displayName)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Object tracking only means something on video.
    private var availableScopes: [BlurScope] {
        session.document.kind == .video
            ? BlurScope.allCases
            : BlurScope.allCases.filter { $0 != .track }
    }

    @ViewBuilder
    private func controls(for region: BlurRegion) -> some View {
        VStack(spacing: 12) {
            switch focus {
            case .blurType:
                styleRow(for: region)
            case .blurMask:
                maskControls(for: region)
            default:
                strengthControls(for: region)
            }

            if focus != .blurType {
                styleRow(for: region)
            }
        }
    }

    private func strengthControls(for region: BlurRegion) -> some View {
        VStack(spacing: 10) {
            KeyframableParameterSlider(
                session: session,
                property: .blurStrength,
                title: String(localized: "Strength", comment: "Blur control"),
                value: Binding(
                    get: { region.strength },
                    set: { value in
                        session.updateBlur(region.id, isFinal: false) { $0.strength = value }
                    }
                ),
                range: 0...1,
                neutral: nil,
                format: { "\(Int(($0 * 100).rounded()))" }
            ) { editing in
                if !editing {
                    session.updateBlur(region.id) { $0.strength = region.strength }
                }
            }

            if region.mask != nil {
                ParameterSlider(
                    title: String(localized: "Feather", comment: "Blur control"),
                    value: Binding(
                        get: { region.mask?.feather ?? 0 },
                        set: { value in
                            session.updateBlur(region.id, isFinal: false) { $0.mask?.feather = value }
                        }
                    ),
                    range: 0...1,
                    neutral: nil,
                    format: { "\(Int(($0 * 100).rounded()))" }
                ) { editing in
                    if !editing {
                        session.updateBlur(region.id) { $0.mask?.feather = region.mask?.feather ?? 0 }
                    }
                }
            }

            if region.scope == .person || region.scope == .background {
                Toggle(isOn: Binding(
                    get: { region.invertsSubject },
                    set: { value in
                        session.updateBlur(region.id) { $0.invertsSubject = value }
                    }
                )) {
                    Text(region.scope == .background
                         ? String(localized: "Keep the subject sharp", comment: "Blur option")
                         : String(localized: "Blur everyone else instead", comment: "Blur option"))
                        .font(.subheadline)
                }
                .toggleStyle(.switch)
            }
        }
    }

    private func maskControls(for region: BlurRegion) -> some View {
        VStack(spacing: 10) {
            if let mask = region.mask, mask.shape.isManipulable {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Self.manipulableShapes, id: \.label) { option in
                            Button {
                                session.updateBlur(region.id) { $0.mask?.shape = option.shape }
                                Haptics.snap()
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: option.shape.symbolName)
                                        .font(.system(size: 16))
                                        .frame(width: 42, height: 42)
                                        .background(
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .fill(matches(mask.shape, option.shape)
                                                      ? Color.accentColor
                                                      : Color(.tertiarySystemFill))
                                        )
                                        .foregroundStyle(matches(mask.shape, option.shape)
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

                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { mask.isInverted },
                        set: { value in
                            session.updateBlur(region.id) { $0.mask?.isInverted = value }
                        }
                    )) {
                        Text("Invert", comment: "Mask option")
                            .font(.subheadline)
                    }
                    .toggleStyle(.switch)

                    Spacer(minLength: 0)

                    // Two branches rather than a ternary: the glass styles are
                    // different concrete types.
                    if session.isTracingFreeformMask {
                        traceButton.buttonStyle(.glassProminent)
                    } else {
                        traceButton.buttonStyle(.glass)
                    }
                }
            } else {
                Text("This blur follows what Frames detects, so there is no shape to edit. Adjust the feather to soften its edge.",
                     comment: "Detected mask explanation")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ParameterSlider(
                    title: String(localized: "Feather", comment: "Blur control"),
                    value: Binding(
                        get: { region.mask?.feather ?? 0 },
                        set: { value in
                            session.updateBlur(region.id, isFinal: false) { $0.mask?.feather = value }
                        }
                    ),
                    range: 0...1,
                    neutral: nil,
                    format: { "\(Int(($0 * 100).rounded()))" }
                ) { editing in
                    if !editing {
                        session.updateBlur(region.id) { $0.mask?.feather = region.mask?.feather ?? 0 }
                    }
                }
            }
        }
    }

    private var traceButton: some View {
        Button {
            session.isTracingFreeformMask.toggle()
            Haptics.snap()
        } label: {
            Label {
                Text("Trace", comment: "Mask action")
            } icon: {
                Image(systemName: "scribble")
            }
            .font(.subheadline)
        }
    }

    private func styleRow(for region: BlurRegion) -> some View {
        SegmentedChoice(
            values: BlurStyle.allCases,
            selection: Binding(
                get: { region.style },
                set: { value in
                    session.updateBlur(region.id) { $0.style = value }
                }
            ),
            label: { $0.displayName },
            symbol: { $0.symbolName }
        )
    }

    private static let manipulableShapes: [(label: String, shape: MaskShape)] = [
        (String(localized: "Rectangle", comment: "Mask shape"), .rectangle),
        (String(localized: "Rounded", comment: "Mask shape"), .roundedRectangle(cornerRadius: 0.08)),
        (String(localized: "Ellipse", comment: "Mask shape"), .ellipse),
        (String(localized: "Linear", comment: "Mask shape"), .linearGradient(angle: 0)),
        (String(localized: "Radial", comment: "Mask shape"), .radialGradient)
    ]

    private func matches(_ lhs: MaskShape, _ rhs: MaskShape) -> Bool {
        switch (lhs, rhs) {
        case (.rectangle, .rectangle),
             (.roundedRectangle, .roundedRectangle),
             (.ellipse, .ellipse),
             (.linearGradient, .linearGradient),
             (.radialGradient, .radialGradient),
             (.freeform, .freeform):
            true
        default:
            false
        }
    }
}
