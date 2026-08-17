import SwiftUI

/// The whole app's navigation, which is two states wide.
struct AppRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app

        ZStack {
            switch app.route {
            case .chooser:
                MediaChooserView()
                    .transition(.opacity)
            case .editor:
                if let session = app.session {
                    EditorView(session: session)
                        .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.28), value: app.route)
        .task {
            await app.prepareForLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await app.session?.saveNow() }
        }
        .alert(
            app.presentedError?.title ?? "",
            isPresented: $app.isShowingError,
            presenting: app.presentedError
        ) { error in
            if error.suggestsSettings {
                Button {
                    app.openSystemSettings()
                } label: {
                    Text("Open Settings", comment: "Alert button")
                }
            }
            Button(role: .cancel) {
                app.presentedError = nil
            } label: {
                Text("OK", comment: "Alert button")
            }
        } message: { error in
            Text(error.message)
        }
        .confirmationDialog(
            Text("You have an unsaved edit.", comment: "Session recovery prompt"),
            isPresented: $app.isShowingRecoveryPrompt,
            titleVisibility: .visible
        ) {
            Button {
                Task { await app.continueRecoveredSession() }
            } label: {
                Text("Continue", comment: "Session recovery action")
            }
            Button(role: .destructive) {
                Task { await app.discardRecoveredSession() }
            } label: {
                Text("Discard", comment: "Session recovery action")
            }
        } message: {
            if let summary = app.recoverableSession {
                Text(summary.promptDetail)
            }
        }
    }
}

#Preview("Chooser") {
    AppRootView()
        .environment(AppModel())
}
