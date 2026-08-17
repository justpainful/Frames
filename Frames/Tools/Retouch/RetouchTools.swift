import SwiftUI

@MainActor
extension EditorSession {

    @discardableResult
    func addRetouchSpot(at position: CGPoint) -> UUID {
        let spot = RetouchSpot(
            kind: retouchTool,
            position: position,
            radius: retouchRadius,
            strength: retouchStrength
        )
        perform(String(localized: "Retouch", comment: "Undo action")) { document in
            document.retouchSpots.append(spot)
        }
        Haptics.edit()
        return spot.id
    }

    func updateRetouchSpot(_ id: UUID, isFinal: Bool = true, _ mutate: (inout RetouchSpot) -> Void) {
        perform(
            String(localized: "Retouch", comment: "Undo action"),
            coalescing: "retouch.\(id)"
        ) { document in
            guard let index = document.retouchSpots.firstIndex(where: { $0.id == id }) else { return }
            mutate(&document.retouchSpots[index])
        }
        if isFinal { endInteraction() }
    }

    func deleteRetouchSpot(_ id: UUID) {
        perform(String(localized: "Remove Retouch", comment: "Undo action")) { document in
            document.retouchSpots.removeAll { $0.id == id }
        }
        Haptics.edit()
    }

    func removeLastRetouchSpot() {
        guard !document.retouchSpots.isEmpty else { return }
        perform(String(localized: "Remove Retouch", comment: "Undo action")) { document in
            document.retouchSpots.removeLast()
        }
        Haptics.edit()
    }
}

/// The Retouch tool.
///
/// Pick a fix, tap the spot. Everything here is local and conservative — there
/// is no reshaping in Frames and there will not be. The panel says so, because
/// people reasonably expect a retouch tool in a video editor to include one.
struct RetouchInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    @State private var tool: RetouchSpot.Kind = .blemish
    @State private var radius: Double = 0.035
    @State private var strength: Double = 0.75

    private var spots: [RetouchSpot] { session.document.retouchSpots }

    var body: some View {
        InspectorSurface(title: String(localized: "Retouch", comment: "Tool title"), onDone: onDone) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(RetouchSpot.Kind.allCases) { kind in
                        Button {
                            tool = kind
                            session.retouchTool = kind
                            Haptics.snap()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: kind.symbolName)
                                    .font(.system(size: 16))
                                Text(kind.displayName)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(tool == kind ? Color.accentColor : Color(.tertiarySystemFill))
                        }
                        .foregroundStyle(tool == kind ? Color.white : Color.primary)
                        .accessibilityLabel(kind.displayName)
                        .accessibilityHint(kind.detail)
                        .accessibilityAddTraits(tool == kind ? [.isSelected, .isButton] : .isButton)
                    }
                }

                Text(tool.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ParameterSlider(
                    title: String(localized: "Size", comment: "Retouch control"),
                    value: Binding(
                        get: { radius },
                        set: { radius = $0; session.retouchRadius = $0 }
                    ),
                    range: 0.01...0.15,
                    neutral: nil,
                    format: { "\(Int(($0 * 1000).rounded()))" }
                )

                ParameterSlider(
                    title: String(localized: "Strength", comment: "Retouch control"),
                    value: Binding(
                        get: { strength },
                        set: { strength = $0; session.retouchStrength = $0 }
                    ),
                    range: 0...1,
                    neutral: nil,
                    format: { "\(Int(($0 * 100).rounded()))" }
                )

                HStack {
                    Text(
                        spots.isEmpty
                            ? String(localized: "Tap the picture to place a fix.",
                                     comment: "Retouch prompt")
                            : String(localized: "\(spots.count) fixes", comment: "Retouch count")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        session.removeLastRetouchSpot()
                    } label: {
                        Label {
                            Text("Undo Last", comment: "Retouch action")
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.glass)
                    .disabled(spots.isEmpty)
                }

                Text("Retouch changes how a small area reads. It never changes anyone's shape.",
                     comment: "Retouch explanation")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            tool = session.retouchTool
            radius = session.retouchRadius
            strength = session.retouchStrength
        }
    }
}

/// Shows where retouch spots are, and lets them be moved or removed.
struct RetouchSpotOverlay: View {
    let session: EditorSession
    let mediaFrame: CGRect

    @State private var dragOrigin: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A transparent surface that turns a tap into a fix.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    session.addRetouchSpot(at: CGPoint(
                        x: location.x / max(mediaFrame.width, 1),
                        y: location.y / max(mediaFrame.height, 1)
                    ))
                }

            ForEach(session.document.retouchSpots) { spot in
                marker(for: spot)
            }
        }
        .frame(width: mediaFrame.width, height: mediaFrame.height)
        .position(x: mediaFrame.midX, y: mediaFrame.midY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Retouch spots", comment: "Accessibility label"))
    }

    private func marker(for spot: RetouchSpot) -> some View {
        let shortEdge = min(mediaFrame.width, mediaFrame.height)
        let diameter = max(spot.radius * shortEdge * 2, 20)
        let centre = CGPoint(
            x: spot.position.x * mediaFrame.width,
            y: spot.position.y * mediaFrame.height
        )

        return Circle()
            .strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: diameter, height: diameter)
            .position(x: centre.x, y: centre.y)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = spot.position
                            Haptics.prepare()
                        }
                        guard let origin = dragOrigin else { return }
                        session.updateRetouchSpot(spot.id, isFinal: false) {
                            $0.position = CGPoint(
                                x: min(max(origin.x + value.translation.width / mediaFrame.width, 0), 1),
                                y: min(max(origin.y + value.translation.height / mediaFrame.height, 0), 1)
                            )
                        }
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        session.endInteraction()
                    }
            )
            .onTapGesture(count: 2) {
                session.deleteRetouchSpot(spot.id)
            }
            .accessibilityLabel(spot.kind.displayName)
            .accessibilityHint(Text("Double tap to remove.", comment: "Accessibility hint"))
    }
}
