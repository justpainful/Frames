import PhotosUI
import SwiftUI

/// The `+` menu: everything that adds a new object to the edit.
///
/// Kept out of the main strip because these are less frequent than the five
/// tools that are always visible, and because a six-item bottom bar is where
/// legibility stops.
struct MoreToolsInspector: View {
    let session: EditorSession
    let onDone: () -> Void

    @Environment(AppModel.self) private var app
    @State private var photoItem: PhotosPickerItem?
    @State private var audioItem: PhotosPickerItem?
    @State private var isShowingAudioImporter = false
    @State private var isImporting = false

    private var isVideo: Bool { session.document.kind == .video }

    var body: some View {
        InspectorSurface(title: String(localized: "Add", comment: "Tool title"), onDone: onDone) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 10)], spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                    tile(symbol: "photo", title: String(localized: "Photo", comment: "Add action"))
                }
                .buttonStyle(.plain)

                button(symbol: "scribble.variable", title: String(localized: "Draw", comment: "Add action")) {
                    _ = session.addDrawing()
                    onDone()
                }

                button(symbol: "sparkles", title: String(localized: "Effects", comment: "Add action")) {
                    route(.effects)
                }

                button(symbol: "person.crop.square.badge.camera", title: String(localized: "Portrait", comment: "Add action")) {
                    route(.portrait)
                }

                button(symbol: "wand.and.rays", title: String(localized: "Retouch", comment: "Add action")) {
                    route(.retouch)
                }

                button(symbol: "circle.dashed.inset.filled", title: String(localized: "Selective", comment: "Add action")) {
                    _ = session.addSelectiveAdjustment()
                    onDone()
                }

                button(symbol: "rectangle.on.rectangle.angled", title: String(localized: "Background", comment: "Add action")) {
                    route(.background)
                }

                if isVideo {
                    button(symbol: "music.note", title: String(localized: "Audio", comment: "Add action")) {
                        isShowingAudioImporter = true
                    }
                    button(symbol: "mic.fill", title: String(localized: "Record", comment: "Add action")) {
                        route(.audio)
                    }
                }

                button(
                    symbol: session.document.safeAreaGuides.isEnabled
                        ? "rectangle.inset.filled.and.person.filled"
                        : "rectangle.dashed",
                    title: String(localized: "Guides", comment: "Add action")
                ) {
                    session.setSafeAreaGuides(enabled: !session.document.safeAreaGuides.isEnabled)
                    Haptics.snap()
                }
            }
            .overlay {
                if isImporting {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
        }
        .fileImporter(
            isPresented: $isShowingAudioImporter,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .movie],
            allowsMultipleSelection: false
        ) { result in
            handleAudioFile(result)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await addPhotoOverlay(item) }
        }
    }

    // MARK: - Pieces

    private func button(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tile(symbol: symbol, title: title)
        }
        .buttonStyle(.plain)
    }

    private func tile(symbol: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private func route(_ detail: EditorDetail) {
        NotificationCenter.default.post(
            name: .framesRequestInspector,
            object: nil,
            userInfo: [FramesInspectorRequest.key: detail.rawValue]
        )
    }

    // MARK: - Importing

    private func addPhotoOverlay(_ item: PhotosPickerItem) async {
        isImporting = true
        defer {
            isImporting = false
            photoItem = nil
        }
        do {
            let asset = try await app.importService.importAsset(from: item)
            _ = session.addImageOverlay(asset: asset)
            onDone()
        } catch let error as FramesError {
            app.present(error)
        } catch {
            app.present(.importFailed(error.localizedDescription))
        }
    }

    private func handleAudioFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result {
                app.present(.importFailed(error.localizedDescription))
            }
            return
        }
        Task {
            isImporting = true
            defer { isImporting = false }
            do {
                let asset = try await AudioImportService().importAudio(fromFileAt: url)
                _ = session.addAudioClip(
                    asset: asset,
                    role: .music,
                    at: session.currentTime,
                    label: url.deletingPathExtension().lastPathComponent
                )
                onDone()
            } catch let error as FramesError {
                app.present(error)
            } catch {
                app.present(.importFailed(error.localizedDescription))
            }
        }
    }
}

/// Lets a nested tool ask the editor to open a different inspector.
///
/// The `+` menu is the one place a control needs to hand off to another tool,
/// and threading a binding through for that single case would complicate every
/// inspector's signature.
enum FramesInspectorRequest {
    static let key = "detail"
}

extension Notification.Name {
    static let framesRequestInspector = Notification.Name("com.frames.Frames.requestInspector")
}
