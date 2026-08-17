import SwiftUI

/// The Frames application entry point.
///
/// Frames deliberately has no document browser, no project list and no sign-in.
/// The app opens straight onto media selection, and everything else is reached
/// by choosing a photo or a video.
@main
struct FramesApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(app)
                .tint(.accentColor)
        }
    }
}
