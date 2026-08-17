import CoreGraphics
import XCTest

/// A guided tour of the app that photographs every screen it can reach.
///
/// This is not a pass/fail test. It drives the real app through the chooser,
/// both editors and every tool, attaching a screenshot at each stop so that a
/// person can page through the run and find the layout, contrast and
/// localisation problems no assertion describes. Only a failure to launch fails
/// the run: an unreachable tool is recorded as a skipped step, because one
/// missing screen must not cost every screen after it.
///
/// The editor is entered through the same generated fixture the smoke tests
/// use, since no UI test can drive the system photo picker.
final class ScreenshotTour: XCTestCase {

    /// Numbers the attachments so the exported files sort in tour order. Each
    /// test claims its own block of numbers, so names stay unique once every
    /// tour's attachments land in the same folder.
    private var stepIndex = 0

    override func setUp() {
        super.setUp()
        // The opposite of the smoke tests: a stop that cannot be reached must
        // not end the tour, so the run continues past anything unexpected.
        continueAfterFailure = true
    }

    // MARK: - Launching

    private func launchApp(fixture: String? = nil, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // `UITestFixtures.shouldResetState()` only looks for the flag itself,
        // but the trailing "1" matches the existing UI tests exactly.
        app.launchArguments = ["-FRAMES_UI_RESET", "1"]
        if let fixture {
            app.launchArguments += ["-FRAMES_UI_TEST_FIXTURE", fixture]
        }
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    /// The standard UI-test overrides for running the app in Arabic.
    private let arabicArguments = ["-AppleLanguages", "(\"ar\")", "-AppleLocale", "ar_SA"]

    // MARK: - Capturing

    /// Attaches a screenshot of the app under a sortable name.
    ///
    /// The app's own screenshot is used rather than the screen's, so the image
    /// is the app and not the simulator's status bar and bezel.
    private func capture(_ name: String, _ app: XCUIApplication) {
        stepIndex += 1
        // SwiftUI animates the inspector in over a quarter of a second, and a
        // screenshot taken mid-transition is not evidence of anything.
        Thread.sleep(forTimeInterval: 0.4)

        let prefix = stepIndex < 10 ? "0\(stepIndex)" : "\(stepIndex)"
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Records a stop the tour could not reach. Deliberately not a failure.
    private func skip(_ message: String) {
        XCTContext.runActivity(named: "Skipped: \(message)") { _ in }
    }

    // MARK: - Finding and tapping

    /// Looks for an element by accessibility label across the three element
    /// types this app puts labels on. Kept to three because every miss costs a
    /// full query, and the tour makes a lot of them.
    ///
    /// `firstMatch` throughout: several labels legitimately appear twice — a
    /// tool strip button and the inspector surface it opens share a title — and
    /// an ambiguous query would raise rather than pick one. Buttons are checked
    /// first so a real control always wins over a container with the same name.
    private func element(anyOf labels: [String], in app: XCUIApplication) -> XCUIElement? {
        for label in labels {
            let button = app.buttons[label].firstMatch
            if button.exists { return button }
            let other = app.otherElements[label].firstMatch
            if other.exists { return other }
            let text = app.staticTexts[label].firstMatch
            if text.exists { return text }
        }
        return nil
    }

    private func element(labeled label: String, in app: XCUIApplication) -> XCUIElement? {
        element(anyOf: [label], in: app)
    }

    /// Polls for an element rather than waiting out a single query's timeout,
    /// so a label that is missing costs the timeout once instead of once per
    /// element type.
    private func waitForElement(
        anyOf labels: [String],
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = element(anyOf: labels, in: app) { return found }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    private func waitForElement(
        labeled label: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        waitForElement(anyOf: [label], in: app, timeout: timeout)
    }

    /// Taps an element, falling back to its centre coordinate.
    ///
    /// Containers such as the canvas carry a tap gesture but report themselves
    /// as not hittable, and `tap()` on those fails the test instead of tapping.
    @discardableResult
    private func tap(_ element: XCUIElement?) -> Bool {
        guard let element, element.exists else { return false }
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    // MARK: - Driving the editor

    /// Taps a bottom strip button and waits for its controls.
    ///
    /// `markers` are labels that only exist once the inspector is up. Most
    /// inspectors have a Done button; Remove Range and Portrait do not, so they
    /// pass something of their own.
    @discardableResult
    private func openTool(
        anyOf labels: [String],
        in app: XCUIApplication,
        expectingAnyOf markers: [String] = ["Done", "تم"]
    ) -> Bool {
        guard let button = waitForElement(anyOf: labels, in: app, timeout: 5) else {
            skip("\(labels[0]) is not on the current tool strip.")
            return false
        }
        tap(button)
        guard waitForElement(anyOf: markers, in: app, timeout: 5) != nil else {
            skip("\(labels[0]) did not open its controls.")
            return false
        }
        return true
    }

    @discardableResult
    private func openTool(
        _ label: String,
        in app: XCUIApplication,
        expecting marker: String = "Done"
    ) -> Bool {
        openTool(anyOf: [label], in: app, expectingAnyOf: [marker])
    }

    /// Closes the open inspector, preferring its Done button and falling back
    /// to tapping the strip button again, which toggles the same route.
    private func closeTool(_ label: String, in app: XCUIApplication) {
        if let done = element(labeled: "Done", in: app) {
            tap(done)
            return
        }
        tap(element(labeled: label, in: app))
    }

    /// Taps the middle of the media, which clears the selection.
    ///
    /// Needed between tools: creating a blur or a text layer selects it, and a
    /// selected object replaces the top-level strip with its own actions.
    private func clearSelection(in app: XCUIApplication) {
        let canvas = element(anyOf: ["Photo preview", "Video preview"], in: app)
        guard let canvas else { return }
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Closes anything open and drops the selection, so the next tool is looked
    /// up on the top-level strip.
    private func resetToTopLevel(in app: XCUIApplication) {
        if let done = element(labeled: "Done", in: app) { tap(done) }
        clearSelection(in: app)
    }

    /// Opens a tool, photographs it and closes it again.
    private func visit(
        tool label: String,
        named name: String,
        in app: XCUIApplication
    ) {
        resetToTopLevel(in: app)
        guard openTool(label, in: app) else { return }
        capture(name, app)
        closeTool(label, in: app)
    }

    // MARK: - Tour 1: photo

    func testPhotoTour() {
        stepIndex = 0

        let chooser = launchApp()
        XCTAssertTrue(chooser.wait(for: .runningForeground, timeout: 30),
                      "The app must launch before anything can be photographed.")
        _ = waitForElement(labeled: "Choose Media", in: chooser, timeout: 30)
        capture("chooser", chooser)
        chooser.terminate()

        let app = launchApp(fixture: "sample-photo")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "The app must launch before anything can be photographed.")
        guard waitForElement(labeled: "Photo preview", in: app, timeout: 30) != nil else {
            skip("The photo fixture never reached the editor.")
            capture("photo-editor-unreachable", app)
            return
        }
        capture("photo-editor", app)

        visit(tool: "Crop", named: "photo-crop", in: app)

        resetToTopLevel(in: app)
        if openTool("Adjust", in: app) {
            capture("photo-adjust", app)
            if let auto = element(labeled: "Auto", in: app) {
                tap(auto)
                // Auto reads a downscaled frame and applies the result, which
                // is fast but not instant.
                Thread.sleep(forTimeInterval: 0.6)
                capture("photo-adjust-auto", app)
            } else {
                skip("Adjust had no Auto button.")
            }
            closeTool("Adjust", in: app)
        }

        resetToTopLevel(in: app)
        if openTool("Filters", in: app) {
            capture("photo-filters", app)
            // The first thumbnail is the unfiltered original, so the second is
            // the first real preset.
            if let preset = element(labeled: "Clean", in: app) {
                tap(preset)
                capture("photo-filters-preset", app)
            } else {
                skip("The filter strip had no second thumbnail.")
            }
            closeTool("Filters", in: app)
        }

        resetToTopLevel(in: app)
        if openTool("Blur", in: app) {
            capture("photo-blur", app)
            if let area = element(labeled: "Area", in: app) {
                tap(area)
                capture("photo-blur-area", app)
            } else {
                skip("The blur scope picker had no Area option.")
            }
            closeTool("Blur", in: app)
        }

        visit(tool: "Text", named: "photo-text", in: app)

        resetToTopLevel(in: app)
        if openTool("More", in: app) {
            capture("photo-more", app)
            if let retouch = element(labeled: "Retouch", in: app) {
                tap(retouch)
                capture("photo-retouch", app)
                closeTool("Retouch", in: app)
            } else {
                skip("The add grid had no Retouch tile.")
            }

            resetToTopLevel(in: app)
            if openTool("More", in: app), let portrait = element(labeled: "Portrait", in: app) {
                tap(portrait)
                // Portrait's controls have no Done button, so the surface's own
                // title is what proves it opened.
                if waitForElement(labeled: "Portrait", in: app, timeout: 5) != nil {
                    capture("photo-portrait", app)
                } else {
                    skip("Portrait did not open its controls.")
                }
            } else {
                skip("The add grid had no Portrait tile.")
            }
        }

        resetToTopLevel(in: app)
        if tap(element(labeled: "Export", in: app)),
           waitForElement(labeled: "Cancel", in: app, timeout: 5) != nil {
            capture("photo-export", app)
            tap(element(labeled: "Cancel", in: app))
        } else {
            skip("The export sheet did not open.")
        }
    }

    // MARK: - Tour 2: video

    func testVideoTour() {
        stepIndex = 29

        let app = launchApp(fixture: "sample-video")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "The app must launch before anything can be photographed.")
        // The video fixture is encoded during launch, so the editor takes
        // longer to appear than the photo one.
        guard waitForElement(labeled: "Play", in: app, timeout: 40) != nil else {
            skip("The video fixture never reached the editor.")
            capture("video-editor-unreachable", app)
            return
        }
        capture("video-editor", app)

        if tap(element(labeled: "Play", in: app)) {
            Thread.sleep(forTimeInterval: 1)
            capture("video-playing", app)
            tap(element(labeled: "Pause", in: app))
        } else {
            skip("The transport had no Play button.")
        }

        clearSelection(in: app)
        visit(tool: "Cut", named: "video-cut", in: app)
        visit(tool: "Adjust", named: "video-adjust", in: app)
        visit(tool: "Filters", named: "video-filters", in: app)
        visit(tool: "Blur", named: "video-blur", in: app)
        visit(tool: "Text", named: "video-text", in: app)
        visit(tool: "More", named: "video-more", in: app)

        // The contextual toolbar is the point of the whole design: selecting a
        // clip must replace the top-level tools with that clip's actions.
        resetToTopLevel(in: app)
        guard let clip = waitForElement(labeled: "Video clip", in: app, timeout: 5) else {
            skip("No clip was found on the timeline.")
            return
        }
        tap(clip)
        capture("video-clip-selected", app)

        if openTool("Speed", in: app) {
            capture("video-clip-speed", app)
            closeTool("Speed", in: app)
        }

        if openTool("Trim", in: app) {
            capture("video-clip-trim", app)
            closeTool("Trim", in: app)
        }

        // Remove Range confirms with Cancel and Delete rather than Done.
        if openTool("Remove Range", in: app, expecting: "Cancel") {
            capture("video-clip-remove-range", app)
            tap(element(labeled: "Cancel", in: app))
        }

        resetToTopLevel(in: app)
        if openTool("Text", in: app) {
            // Text puts the keyboard up as soon as the layer exists, which is
            // the layout worth photographing.
            capture("video-text-keyboard", app)
            closeTool("Text", in: app)
        }

        resetToTopLevel(in: app)
        if tap(element(labeled: "Export", in: app)),
           waitForElement(labeled: "Cancel", in: app, timeout: 5) != nil {
            capture("video-export", app)
            if tap(element(labeled: "Advanced", in: app)) {
                capture("video-export-advanced", app)
            } else {
                skip("The export sheet had no Advanced section.")
            }
            tap(element(labeled: "Cancel", in: app))
        } else {
            skip("The export sheet did not open.")
        }
    }

    // MARK: - Tour 3: Arabic

    /// The same two screens in a right-to-left language.
    ///
    /// Labels are looked up in Arabic first and English second, so the tour
    /// still finds its way if the runtime falls back to the base localisation.
    func testArabicTour() {
        stepIndex = 59

        let chooser = launchApp(extraArguments: arabicArguments)
        XCTAssertTrue(chooser.wait(for: .runningForeground, timeout: 30),
                      "The app must launch before anything can be photographed.")
        _ = waitForElement(anyOf: ["اختر وسائط", "Choose Media"], in: chooser, timeout: 30)
        capture("arabic-chooser", chooser)
        chooser.terminate()

        let app = launchApp(fixture: "sample-photo", extraArguments: arabicArguments)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "The app must launch before anything can be photographed.")
        guard waitForElement(anyOf: ["معاينة الصورة", "Photo preview"], in: app, timeout: 30) != nil else {
            skip("The photo fixture never reached the editor in Arabic.")
            capture("arabic-editor-unreachable", app)
            return
        }
        capture("arabic-photo-editor", app)

        if openTool(anyOf: ["تعديل", "Adjust"], in: app) {
            capture("arabic-adjust", app)
        }
    }

    // MARK: - Accessibility audit

    /// Reports what the system audit finds on the photo editor.
    ///
    /// Findings are attached as text and never fail the run: this job exists to
    /// hand a person material to look at, and an audit that blocks the build
    /// would only be turned off.
    func testAccessibilityAudit() {
        stepIndex = 90

        let app = launchApp(fixture: "sample-photo")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                      "The app must launch before anything can be audited.")
        guard waitForElement(labeled: "Photo preview", in: app, timeout: 30) != nil else {
            skip("The photo fixture never reached the editor, so there was nothing to audit.")
            return
        }

        guard #available(iOS 17.0, *) else {
            skip("The accessibility audit needs iOS 17 or newer.")
            return
        }

        var findings: [String] = []
        do {
            try app.performAccessibilityAudit { issue in
                findings.append(String(describing: issue))
                // True marks the issue as handled, which is what keeps the
                // audit from failing the test.
                return true
            }
        } catch {
            findings.append("The audit could not run: \(error.localizedDescription)")
        }

        let report = findings.isEmpty
            ? "No accessibility audit findings on the photo editor."
            : findings.joined(separator: "\n\n")

        XCTContext.runActivity(named: "Accessibility audit: \(findings.count) finding(s)") { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = "90-accessibility-audit"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        capture("accessibility-audit-screen", app)
    }
}
