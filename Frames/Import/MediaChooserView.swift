import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The first screen.
///
/// One decision, one button. The app does not ask whether this is a photo
/// project or a video project — it looks at what was chosen and opens the right
/// editor.
struct MediaChooserView: View {
    @Environment(AppModel.self) private var app
    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingFileImporter = false
    @State private var recents = RecentMediaProvider()

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            // The mark, the sentence and the button are one block, sitting a
            // little above centre. The earlier layout pushed them to opposite
            // ends of the screen with the recents strip stranded at the bottom,
            // which read as three unrelated things rather than one choice.
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                VStack(spacing: 12) {
                    FramesMark()
                        .frame(width: 72, height: 72)
                        .padding(.bottom, 2)

                    Text("Frames", comment: "App name")
                        .font(.system(.largeTitle, design: .default, weight: .semibold))

                    Text("Choose a photo or video", comment: "Chooser subtitle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                chooseButton
                    .padding(.horizontal, 32)
                    .padding(.top, 32)

                secondaryActions
                    .padding(.top, 12)

                Spacer(minLength: 12)

                recentsStrip
                    .padding(.bottom, 4)
            }
            .padding(.vertical, 20)

            if app.isImporting {
                importingOverlay
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.movie, .image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .task {
            await recents.loadIfAuthorized()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await app.importAndOpen { try await app.importService.importAsset(from: item) }
                pickerItem = nil
            }
        }
    }

    // MARK: - Pieces

    private var chooseButton: some View {
        PhotosPicker(
            selection: $pickerItem,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        ) {
            Label {
                Text("Choose Media", comment: "Primary action")
                    .font(.headline)
            } icon: {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityHint(Text("Opens your photo library so you can pick something to edit.",
                                comment: "Accessibility hint"))
    }

    private var secondaryActions: some View {
        Button {
            isShowingFileImporter = true
        } label: {
            Text("Browse Files", comment: "Secondary action")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityHint(Text("Choose a photo or video stored in Files.", comment: "Accessibility hint"))
    }

    @ViewBuilder
    private var recentsStrip: some View {
        if !recents.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recents", comment: "Recents section title")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(recents.items) { item in
                            RecentThumbnailButton(item: item) {
                                Task {
                                    await app.importAndOpen { try await recents.loadAsset(for: item) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
                .frame(height: 84)
            }
            .padding(.top, 8)
        } else if recents.canRequestAccess {
            Button {
                Task { await recents.requestAccessAndLoad() }
            } label: {
                Text("Show Recents", comment: "Enables the recents strip")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.6).ignoresSafeArea()
            ProgressView()
                .controlSize(.large)
                .padding(28)
                .glassEffect(in: .rect(cornerRadius: 22))
        }
        .transition(.opacity)
        .accessibilityLabel(Text("Preparing media", comment: "Accessibility label"))
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                await app.importAndOpen { try await app.importService.importAsset(fromFileAt: url) }
            }
        case .failure(let error):
            app.present(.importFailed(error.localizedDescription))
        }
    }
}

/// One tile in the recents strip.
private struct RecentThumbnailButton: View {
    let item: RecentMediaItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(uiImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video {
                        Text(item.duration.framesShortTimecode)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            item.kind == .video
                ? Text("Recent video", comment: "Accessibility label")
                : Text("Recent photo", comment: "Accessibility label")
        )
    }
}
