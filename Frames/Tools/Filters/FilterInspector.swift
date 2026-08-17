import CoreImage
import SwiftUI

/// The Filters tool.
///
/// Every thumbnail is the user's own frame with the filter actually applied,
/// built from a single small decode rather than one per filter. Choosing a
/// filter reveals its intensity; nothing is baked into the source.
struct FilterInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    @State private var category: FilterCategory = .natural
    @State private var thumbnails: [String: CGImage] = [:]
    @State private var sourceImage: CIImage?

    private var currentFilter: FilterInstance? { session.document.grade.filter }

    var body: some View {
        InspectorSurface(title: String(localized: "Filters", comment: "Tool title"), onDone: onDone) {
            VStack(spacing: 12) {
                if let filter = currentFilter {
                    ParameterSlider(
                        title: filter.preset?.displayName
                            ?? String(localized: "Intensity", comment: "Filter control"),
                        value: Binding(
                            get: { filter.intensity },
                            set: { session.setFilterIntensity($0, isFinal: false) }
                        ),
                        range: 0...1,
                        neutral: nil,
                        format: { "\(Int(($0 * 100).rounded()))" }
                    ) { editing in
                        if !editing {
                            session.setFilterIntensity(filter.intensity, isFinal: true)
                        }
                    }
                }

                thumbnailStrip

                SegmentedChoice(
                    values: FilterCategory.allCases,
                    selection: $category,
                    label: { $0.displayName }
                )
            }
        }
        .task {
            await loadSource()
        }
        .task(id: category) {
            await buildThumbnails()
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                thumbnail(for: FilterCatalog.none)
                ForEach(FilterCatalog.presets(in: category)) { preset in
                    thumbnail(for: preset)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func thumbnail(for preset: FilterPreset) -> some View {
        let isSelected = (currentFilter?.presetID ?? FilterCatalog.none.id) == preset.id
        return Button {
            session.setFilter(preset.id == FilterCatalog.none.id ? nil : preset.id)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    if let image = thumbnails[preset.id] {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(width: 54, height: 54)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.clear,
                            lineWidth: 2.5
                        )
                }

                Text(preset.displayName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .frame(width: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func loadSource() async {
        sourceImage = await VideoFrameSampler.representativeImage(
            for: session.document,
            at: session.currentTime,
            maxPixelSize: 220
        )
        await buildThumbnails()
    }

    private func buildThumbnails() async {
        guard let sourceImage else { return }
        let context = RenderContext.shared.preview
        let size = CGSize(width: 110, height: 110)

        var built: [String: CGImage] = thumbnails
        let presets = [FilterCatalog.none] + FilterCatalog.presets(in: category)
        for preset in presets {
            if Task.isCancelled { return }
            guard built[preset.id] == nil else { continue }
            if let image = FilterRenderer.thumbnail(
                of: preset,
                from: sourceImage,
                context: context,
                size: size
            ) {
                built[preset.id] = image
            }
        }
        thumbnails = built
    }
}

/// The Effects browser.
struct EffectsInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    @State private var category: EffectCategory = .basic

    private func effect(_ kind: EffectKind) -> EffectInstance? {
        session.document.effects.first { $0.kind == kind }
    }

    var body: some View {
        InspectorSurface(title: String(localized: "Effects", comment: "Tool title"), onDone: onDone) {
            VStack(spacing: 12) {
                if let active = session.document.effects.first(where: { $0.kind.category == category }) {
                    ParameterSlider(
                        title: active.kind.displayName,
                        value: Binding(
                            get: { active.intensity },
                            set: { session.setEffectIntensity(active.id, to: $0, isFinal: false) }
                        ),
                        range: 0...1,
                        neutral: nil,
                        format: { "\(Int(($0 * 100).rounded()))" }
                    ) { editing in
                        if !editing {
                            session.setEffectIntensity(active.id, to: active.intensity, isFinal: true)
                        }
                    }
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(EffectKind.allCases.filter { $0.category == category }) { kind in
                            let isActive = effect(kind) != nil
                            Button {
                                if isActive {
                                    session.removeEffect(kind: kind)
                                } else {
                                    _ = session.addEffect(kind)
                                }
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: kind.symbolName)
                                        .font(.system(size: 18))
                                        .frame(width: 46, height: 46)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(isActive ? Color.accentColor : Color(.tertiarySystemFill))
                                        )
                                        .foregroundStyle(isActive ? Color.white : Color.primary)
                                    Text(kind.displayName)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 62)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(kind.displayName)
                            .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)

                SegmentedChoice(
                    values: EffectCategory.allCases,
                    selection: $category,
                    label: { $0.displayName }
                )
            }
        }
    }
}
