import CoreImage
import SwiftUI

/// Lets the user say which face to blur.
///
/// Blur → Face → tap the face. That is the whole interaction, and it is why
/// detection runs here rather than silently: the user has to be able to see
/// what Frames found and choose between two faces in the same frame.
///
/// Picking a face writes both the detection's identifier *and* its rectangle
/// into the mask. The identifier is what the renderer looks up; the rectangle
/// is the hint that lets later frames re-match the same face as it moves.
struct FacePickerOverlay: View {
    let session: EditorSession
    let regionID: UUID
    let mediaFrame: CGRect

    @State private var faces: [DetectedFace] = []
    @State private var isDetecting = false
    @State private var foundNothing = false

    private var region: BlurRegion? {
        session.document.blurRegions.first { $0.id == regionID }
    }

    private var selectedFaceID: UUID? {
        guard case .face(let id) = region?.mask?.shape else { return nil }
        return id
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(faces) { face in
                marker(for: face)
            }

            if isDetecting {
                ProgressView()
                    .controlSize(.regular)
                    .padding(14)
                    .glassEffect(in: .rect(cornerRadius: 16))
                    .position(x: mediaFrame.width / 2, y: mediaFrame.height / 2)
            } else if foundNothing {
                Text("No faces found in this frame.", comment: "Face blur status")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .position(x: mediaFrame.width / 2, y: mediaFrame.height / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: mediaFrame.width, height: mediaFrame.height)
        .position(x: mediaFrame.midX, y: mediaFrame.midY)
        .task(id: detectionKey) { await detect() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Detected faces", comment: "Accessibility label"))
    }

    /// Re-detect when the playhead moves far enough that the faces will have.
    private var detectionKey: Int {
        Int((session.currentTime * 2).rounded())
    }

    private func marker(for face: DetectedFace) -> some View {
        let isSelected = selectedFaceID == face.id
        let rect = CGRect(
            x: face.rect.minX * mediaFrame.width,
            y: face.rect.minY * mediaFrame.height,
            width: face.rect.width * mediaFrame.width,
            height: face.rect.height * mediaFrame.height
        )

        return Ellipse()
            .strokeBorder(
                isSelected ? Color.accentColor : Color.white.opacity(0.9),
                style: StrokeStyle(lineWidth: isSelected ? 3 : 1.5, dash: isSelected ? [] : [6, 4])
            )
            .background(
                Ellipse().fill(Color.accentColor.opacity(isSelected ? 0.18 : 0.001))
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .contentShape(Ellipse())
            .onTapGesture { select(face) }
            .accessibilityLabel(Text("Face", comment: "Accessibility label"))
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func select(_ face: DetectedFace) {
        session.updateBlur(regionID) { region in
            region.mask?.shape = .face(detectionID: face.id)
            // The rectangle is the hint the renderer re-matches against on
            // later frames, so it has to be written alongside the identifier.
            region.mask?.transform.position = CGPoint(x: face.rect.midX, y: face.rect.midY)
            region.mask?.size = CGSize(width: face.rect.width, height: face.rect.height)
            region.mask?.transform.scale = 1
        }
        Haptics.edit()
    }

    private func detect() async {
        guard region != nil else { return }
        isDetecting = true
        foundNothing = false
        defer { isDetecting = false }

        guard let image = await VideoFrameSampler.representativeImage(
            for: session.document,
            at: session.currentTime,
            maxPixelSize: 1024
        ) else {
            foundNothing = true
            return
        }

        do {
            // Passing the previous result lets detections keep their ids
            // between passes, so a selected face stays selected while scrubbing.
            let found = try await VisionService.shared.detectFaces(in: image, existing: faces)
            faces = found
            foundNothing = found.isEmpty
        } catch {
            faces = []
            foundNothing = true
        }
    }
}

/// Lets the user pick which person a person blur applies to.
///
/// Person instances have no meaningful names, so the choice is presented as
/// numbered instances over the picture rather than as a list.
struct PersonPickerOverlay: View {
    let session: EditorSession
    let regionID: UUID
    let mediaFrame: CGRect

    @State private var instanceCount = 0
    @State private var isDetecting = false

    private var region: BlurRegion? {
        session.document.blurRegions.first { $0.id == regionID }
    }

    private var selectedInstance: Int? {
        guard case .person(let instance) = region?.mask?.shape else { return nil }
        return instance
    }

    var body: some View {
        VStack {
            Spacer()
            if isDetecting {
                ProgressView().controlSize(.small)
            } else if instanceCount > 1 {
                HStack(spacing: 8) {
                    ForEach(1...instanceCount, id: \.self) { instance in
                        Button {
                            session.updateBlur(regionID) { $0.mask?.shape = .person(instance: instance) }
                            Haptics.snap()
                        } label: {
                            Text("\(instance)")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .background {
                            Circle().fill(
                                selectedInstance == instance
                                    ? Color.accentColor
                                    : Color.black.opacity(0.5)
                            )
                        }
                        .foregroundStyle(.white)
                        .accessibilityLabel(
                            Text("Person \(instance)", comment: "Person blur choice")
                        )
                        .accessibilityAddTraits(
                            selectedInstance == instance ? [.isSelected, .isButton] : .isButton
                        )
                    }
                }
                .padding(8)
                .glassEffect(in: .capsule)
                .padding(.bottom, 14)
            }
        }
        .frame(width: mediaFrame.width, height: mediaFrame.height)
        .position(x: mediaFrame.midX, y: mediaFrame.midY)
        .task { await count() }
    }

    private func count() async {
        isDetecting = true
        defer { isDetecting = false }
        guard let image = await VideoFrameSampler.representativeImage(
            for: session.document,
            at: session.currentTime,
            maxPixelSize: 768
        ) else { return }
        let masks = (try? await VisionService.shared.personMasks(in: image)) ?? [:]
        instanceCount = masks.count
    }
}
