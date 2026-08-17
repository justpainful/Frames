import SwiftUI

/// One item in a bottom tool strip.
struct ToolStripItem: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    var isDestructive = false
    var isProminent = false

    init(id: String, title: String, symbol: String, isDestructive: Bool = false, isProminent: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.isProminent = isProminent
    }
}

/// The horizontal row of icon-and-label buttons at the bottom of the editor.
///
/// This is the whole contextual-tools mechanism at the presentation layer: the
/// items are a function of what is selected, so tapping an object swaps the row
/// for that object's actions.
struct ToolStrip: View {
    let items: [ToolStripItem]
    var selected: String?
    /// Shown at the leading edge when something is selected, so there is always
    /// a visible way back to the app's top-level tools. Tapping the background
    /// works too, but a strip that changed under you needs a door out of it.
    var onBack: (() -> Void)?
    let action: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 34, height: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Back to tools", comment: "Editor action"))

                Divider()
                    .frame(height: 26)
                    .padding(.trailing, 2)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        Button {
                            action(item.id)
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 18, weight: .regular))
                                    .frame(height: 21)
                                Text(item.title)
                                    .font(.system(size: 10.5))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                            // Sized so the six top-level tools fit a standard
                            // iPhone without scrolling. Anything wider and the
                            // last one hides off-screen, which reads as five
                            // tools rather than six.
                            .frame(minWidth: 56)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tint(for: item))
                        .background {
                            if selected == item.id {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                            }
                        }
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(selected == item.id ? [.isSelected, .isButton] : .isButton)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            // Fades the cut edge so a strip that continues past the screen
            // looks deliberate rather than clipped.
            .mask(EdgeFade(leading: onBack != nil))
        }
        .padding(.horizontal, 6)
    }

    private func tint(for item: ToolStripItem) -> Color {
        if item.isDestructive { return .red }
        if item.isProminent || selected == item.id { return .accentColor }
        return .primary
    }
}

/// A soft edge for horizontally scrolling strips.
///
/// A strip that simply stops mid-item looks broken; the same strip fading out
/// reads as "there is more this way".
struct EdgeFade: View {
    var leading = false
    var width: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: gradientStops(width: proxy.size.width),
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func gradientStops(width: CGFloat) -> [Gradient.Stop] {
        guard width > width * 0 else { return [] }
        let fade = width > 0 ? min(self.width / width, 0.2) : 0
        var stops: [Gradient.Stop] = []
        if leading {
            stops.append(.init(color: .clear, location: 0))
            stops.append(.init(color: .black, location: fade))
        } else {
            stops.append(.init(color: .black, location: 0))
        }
        stops.append(.init(color: .black, location: 1 - fade))
        stops.append(.init(color: .clear, location: 1))
        return stops
    }
}

/// The surface a tool's controls sit on.
///
/// Liquid Glass is used here rather than everywhere: floating editing controls
/// over the media is exactly what it is for, and the media stays the dominant
/// thing on screen.
struct InspectorSurface<Content: View>: View {
    let title: String
    var onDone: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let onDone {
                    Button(action: onDone) {
                        Text("Done", comment: "Closes a tool")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }

            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.clear)
                .glassEffect(in: .rect(cornerRadius: 22))
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A row of small, tappable colour swatches.
struct ColorSwatchRow: View {
    @Binding var color: RGBAColor
    var includesClear = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if includesClear {
                    swatch(.clear, isClear: true)
                }
                ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { _, option in
                    swatch(option, isClear: false)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel(Text("Color", comment: "Accessibility label"))
    }

    private func swatch(_ option: RGBAColor, isClear: Bool) -> some View {
        let isSelected = color == option
        return Button {
            color = option
            Haptics.snap()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(option))
                    .frame(width: 28, height: 28)
                if isClear {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                Circle()
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                        lineWidth: isSelected ? 2.5 : 1
                    )
                    .frame(width: 32, height: 32)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

extension Color {
    /// Bridges the document's stored colour into SwiftUI.
    init(_ color: RGBAColor) {
        self.init(
            .sRGB,
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }
}
