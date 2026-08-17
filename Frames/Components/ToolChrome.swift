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
    let action: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    Button {
                        action(item.id)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 19, weight: .regular))
                                .frame(height: 22)
                            Text(item.title)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .frame(minWidth: 62)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
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
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func tint(for item: ToolStripItem) -> Color {
        if item.isDestructive { return .red }
        if item.isProminent || selected == item.id { return .accentColor }
        return .primary
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
