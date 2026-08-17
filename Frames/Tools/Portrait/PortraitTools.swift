import SwiftUI

/// The Portrait tool.
///
/// One switch, four starting points and the individual amounts underneath. The
/// presets are where almost everyone should stop: the sliders exist because
/// rooms differ, not because the presets are incomplete.
struct PortraitInspector: View {
    let session: EditorSession
    var onDone: (() -> Void)?

    private var portrait: PortraitSettings { session.document.portrait }
    private var selectedPreset: PortraitSettings.Preset? { portrait.matchingPreset }

    var body: some View {
        InspectorSurface(title: String(localized: "Portrait", comment: "Tool title"), onDone: onDone) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { portrait.isEnabled },
                    set: { session.setPortraitEnabled($0) }
                )) {
                    Text("Portrait Mode", comment: "Portrait control")
                        .font(.subheadline.weight(.medium))
                }
                .toggleStyle(.switch)

                presetRow

                amounts
                    .disabled(!portrait.isEnabled)
                    // Dimmed rather than hidden: the amounts are part of what
                    // the tool is, and hiding them would make the panel jump.
                    .opacity(portrait.isEnabled ? 1 : 0.45)
            }
        }
    }

    // MARK: - Presets

    private var presetRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(PortraitSettings.Preset.allCases) { preset in
                    Button {
                        session.applyPortraitPreset(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(preset.detail)
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .opacity(0.75)
                        }
                        .frame(width: 136, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selectedPreset == preset ? Color.accentColor : Color(.tertiarySystemFill))
                    }
                    .foregroundStyle(selectedPreset == preset ? Color.white : Color.primary)
                    .accessibilityLabel(preset.displayName)
                    .accessibilityHint(preset.detail)
                    .accessibilityAddTraits(selectedPreset == preset ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Amounts

    private var amounts: some View {
        ScrollView {
            VStack(spacing: 12) {
                slider(String(localized: "Smoothing", comment: "Portrait control"), \.smoothing)
                slider(String(localized: "Detail", comment: "Portrait control"), \.detailPreservation)
                slider(String(localized: "Hair & Spots", comment: "Portrait control"), \.hairRemoval)
                slider(String(localized: "Low Light", comment: "Portrait control"), \.lowLight)
                slider(String(localized: "Color Noise", comment: "Portrait control"), \.colorNoiseReduction)
                slider(String(localized: "Glow", comment: "Portrait control"), \.glow)
                slider(String(localized: "Evenness", comment: "Portrait control"), \.evenness)
                slider(String(localized: "Warmth", comment: "Portrait control"), \.warmth)
                slider(String(localized: "Stability", comment: "Portrait control"), \.temporalStability)

                Toggle(isOn: Binding(
                    get: { portrait.restrictToPeople },
                    set: { restrict in
                        var settings = session.document.portrait
                        settings.restrictToPeople = restrict
                        session.setPortrait(settings)
                        Haptics.snap()
                    }
                )) {
                    Text("People Only", comment: "Portrait control")
                        .font(.subheadline.weight(.medium))
                }
                .toggleStyle(.switch)
            }
            .padding(.bottom, 2)
        }
        // Tall enough for three amounts at once, short enough that the picture
        // stays the biggest thing on screen.
        .frame(maxHeight: 250)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<PortraitSettings, Double>
    ) -> some View {
        ParameterSlider(
            title: title,
            value: Binding(
                get: { session.document.portrait[keyPath: keyPath] },
                set: { newValue in
                    var settings = session.document.portrait
                    settings[keyPath: keyPath] = newValue
                    session.setPortrait(settings, isFinal: false)
                }
            ),
            range: 0...1,
            neutral: nil,
            format: { "\(Int(($0 * 100).rounded()))" }
        ) { editing in
            if !editing {
                session.setPortrait(session.document.portrait, isFinal: true)
            }
        }
    }
}

// MARK: - Actions

@MainActor
extension EditorSession {

    /// The single door every Portrait change goes through.
    ///
    /// Continuous drags coalesce under one token so a whole gesture is one undo
    /// step, exactly as the other continuous controls do.
    func setPortrait(_ settings: PortraitSettings, isFinal: Bool = true) {
        // Round-tripping through the initialiser is what clamps the values. The
        // stored properties are plain vars, so a caller — or a key path write
        // from a slider — can put anything into them.
        let normalized = PortraitSettings(
            isEnabled: settings.isEnabled,
            smoothing: settings.smoothing,
            detailPreservation: settings.detailPreservation,
            hairRemoval: settings.hairRemoval,
            lowLight: settings.lowLight,
            colorNoiseReduction: settings.colorNoiseReduction,
            glow: settings.glow,
            evenness: settings.evenness,
            warmth: settings.warmth,
            temporalStability: settings.temporalStability,
            restrictToPeople: settings.restrictToPeople
        )

        guard normalized != document.portrait else {
            // Nothing moved. Recording it would leave an undo step that undoes
            // nothing, which is what makes an editor's undo stack untrustworthy.
            if isFinal { endInteraction() }
            return
        }

        perform(
            String(localized: "Portrait", comment: "Undo action"),
            coalescing: "portrait"
        ) { document in
            document.portrait = normalized
        }
        if isFinal { endInteraction() }
    }

    /// Applies a preset. Presets turn Portrait on, because choosing one is
    /// unambiguously asking for it.
    func applyPortraitPreset(_ preset: PortraitSettings.Preset) {
        perform(String(localized: "Portrait Preset", comment: "Undo action")) { document in
            document.portrait = preset.settings
        }
        Haptics.snap()
    }

    func setPortraitEnabled(_ enabled: Bool) {
        guard document.portrait.isEnabled != enabled else { return }
        perform(String(localized: "Portrait", comment: "Undo action")) { document in
            document.portrait.isEnabled = enabled
        }
        Haptics.snap()
    }
}
