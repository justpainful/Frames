import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

/// Where the app currently is. Frames only ever has two places to be: choosing
/// media, or editing it.
enum AppRoute: Equatable, Hashable, Sendable {
    case chooser
    case editor
}

/// A summary of an interrupted edit, shown on the recovery prompt.
struct RecoverableSessionSummary: Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: MediaKind
    let modifiedAt: Date

    var promptDetail: String {
        let when = modifiedAt.formatted(date: .omitted, time: .shortened)
        switch kind {
        case .photo:
            return String(localized: "A photo edit from \(when).", comment: "Recovery detail")
        case .video:
            return String(localized: "A video edit from \(when).", comment: "Recovery detail")
        }
    }
}

/// Root application state.
///
/// Deliberately small: it owns navigation and the one recoverable editing
/// session, and nothing else. Editing state lives in `EditorSession`, media
/// work lives in the services, and neither is reachable from here except
/// through the session the user is currently editing.
@MainActor
@Observable
final class AppModel {
    private(set) var route: AppRoute = .chooser

    /// The live editing session, if the user is editing something.
    private(set) var session: EditorSession?

    /// Set when a previous run left an unsaved edit behind. Presenting this is
    /// crash recovery, not project management: the user either continues or
    /// discards, and it never appears again for the same edit.
    private(set) var recoverableSession: RecoverableSessionSummary?
    var isShowingRecoveryPrompt = false

    var presentedError: FramesError?
    var isShowingError: Bool {
        get { presentedError != nil }
        set { if !newValue { presentedError = nil } }
    }

    /// True while media is being brought in, so the chooser can show progress
    /// without blocking the interface.
    private(set) var isImporting = false

    let importService = MediaImportService()
    let store = SessionRecoveryStore()
    private let logger = FramesLog.editor

    init() {}

    // MARK: - Launch

    func prepareForLaunch() async {
        guard route == .chooser, session == nil else { return }
        do {
            try SessionPaths.createDirectories()
        } catch {
            logger.error("Could not create session directories: \(error.localizedDescription, privacy: .public)")
        }
        SessionPaths.pruneScratch()
        SessionPaths.pruneCaches()

        #if DEBUG
        if UITestFixtures.shouldResetState() {
            await store.discard()
        }
        if let fixture = UITestFixtures.requestedFixture() {
            await openFixture(fixture)
            return
        }
        #endif

        if let summary = await store.summary() {
            recoverableSession = summary
            isShowingRecoveryPrompt = true
        }
    }

    // MARK: - Errors

    func present(_ error: FramesError) {
        guard error != .cancelled else { return }
        logger.error("Presenting error: \(error.logDescription, privacy: .public)")
        presentedError = error
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Import

    /// Opens the editor for an asset the user just chose. The route changes as
    /// soon as the asset is described, so the editor appears immediately and
    /// any further loading happens behind the media that is already on screen.
    func openEditor(with asset: SourceAsset) {
        let document = importService.makeDocument(for: asset)
        open(EditorSession(document: document, store: store))
    }

    func importAndOpen(_ operation: @escaping () async throws -> SourceAsset) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let asset = try await operation()
            openEditor(with: asset)
        } catch let error as FramesError {
            present(error)
        } catch {
            present(.importFailed(error.localizedDescription))
        }
    }

    // MARK: - Session lifetime

    func open(_ session: EditorSession) {
        self.session = session
        route = .editor
        recoverableSession = nil
        isShowingRecoveryPrompt = false
    }

    /// Leaves the editor. The session's work stays on disk so it can be
    /// recovered; only an export or an explicit discard removes it.
    func closeEditor() {
        session = nil
        route = .chooser
    }

    /// Leaves the editor and throws the edit away.
    func discardAndCloseEditor() async {
        await session?.finish()
        session = nil
        route = .chooser
    }

    func continueRecoveredSession() async {
        isShowingRecoveryPrompt = false
        guard let document = await store.load() else {
            recoverableSession = nil
            present(.sessionRecoveryFailed("document unreadable"))
            return
        }
        open(EditorSession(document: document, store: store))
    }

    func discardRecoveredSession() async {
        isShowingRecoveryPrompt = false
        recoverableSession = nil
        await store.discard()
    }

    #if DEBUG
    private func openFixture(_ fixture: UITestFixtures.Fixture) async {
        do {
            let asset = try await UITestFixtures.makeAsset(fixture)
            openEditor(with: asset)
        } catch {
            logger.error("Fixture load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
