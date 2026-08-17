import XCTest

/// Smoke tests that drive the real app.
///
/// The editor is entered through a generated fixture rather than the system
/// photo picker, which no UI test can drive reliably. The fixture path exists
/// only in debug builds.
final class FramesUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp(fixture: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FRAMES_UI_RESET", "1"]
        if let fixture {
            app.launchArguments += ["-FRAMES_UI_TEST_FIXTURE", fixture]
        }
        app.launch()
        return app
    }

    func testAppLaunches() {
        let app = launchApp()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    }

    func testChooserShowsTheChoice() {
        let app = launchApp()
        let chooseButton = app.buttons["Choose Media"]
        XCTAssertTrue(chooseButton.waitForExistence(timeout: 20),
                      "The first screen must make it obvious how to start.")
        XCTAssertTrue(app.staticTexts["Choose a photo or video"].exists)
    }

    func testPhotoFixtureOpensTheEditor() {
        let app = launchApp(fixture: "sample-photo")
        let canvas = app.otherElements["Photo preview"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 30),
                      "Choosing a photo must land straight in the photo editor.")
        XCTAssertTrue(app.buttons["Close"].exists)
    }

    func testVideoFixtureOpensTheEditorWithTransport() {
        let app = launchApp(fixture: "sample-video")
        let playButton = app.buttons["Play"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 40),
                      "Choosing a video must land straight in the video editor.")
        XCTAssertTrue(app.buttons["Undo"].exists)
        XCTAssertTrue(app.buttons["Redo"].exists)
    }

    func testUndoAndRedoStartDisabled() {
        let app = launchApp(fixture: "sample-photo")
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 30))
        XCTAssertFalse(undo.isEnabled, "Nothing has been changed yet.")
        XCTAssertFalse(app.buttons["Redo"].isEnabled)
    }
}
