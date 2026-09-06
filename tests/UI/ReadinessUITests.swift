import XCTest
import AppKit

final class ReadinessUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate() }

    private func launch(_ scenario: String = "ready") {
        app = XCUIApplication()
        // AppKit can treat unknown arguments as file-open requests, suppressing
        // the initial window. Keep test setup out of the document-open path.
        app.launchEnvironment["XVD_UI_TESTING"] = "1"
        app.launchEnvironment["XVD_UI_SCENARIO"] = scenario
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.windows["Xbox Voice Deck"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["simulation.banner"].waitForExistence(timeout: 10))
    }
    private func tab(_ name: String) {
        let radio = app.radioButtons[name]
        if radio.exists { radio.click() } else { app.buttons[name].click() }
    }
    private func visible(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(element.isHittable, "Expected visible control: \(element)")
    }
    private func waitText(_ id: String, contains value: String) {
        let condition = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
        expectation(for: condition, evaluatedWith: app.staticTexts[id])
        waitForExpectations(timeout: 5)
    }
    private func start() {
        app.buttons["routing.startStop"].click()
        waitText("routing.status", contains: "CONNECTED")
    }
    private func toggle(_ id: String) -> XCUIElement {
        let checkbox = app.checkBoxes[id]
        return checkbox.exists ? checkbox : app.switches[id]
    }

    func testMissingDevicesRemainBlockedAndShowActionableError() {
        launch("missing")
        tab("Preflight")
        waitText("preflight.summary", contains: "blocked")
        app.buttons["routing.startStop"].click()
        XCTAssertTrue(app.staticTexts["routing.error"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["routing.startStop"].label, "Start muted")
    }

    func testPermissionDeniedStaysStopped() {
        launch("denied")
        app.buttons["routing.startStop"].click()
        waitText("routing.status", contains: "PERMISSION DENIED")
        waitText("routing.error", contains: "Microphone")
        XCTAssertEqual(app.buttons["routing.startStop"].label, "Start muted")
    }

    func testReadyPreflightAndMutedStartStop() {
        launch()
        tab("Preflight")
        waitText("preflight.summary", contains: "muted start")
        start()
        waitText("routing.status", contains: "muted")
        app.buttons["routing.startStop"].click()
        waitText("routing.status", contains: "STOPPED")
    }

    func testClosingWindowQuitsAndRelaunchStartsStopped() {
        launch(); start()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        XCTAssertTrue(app.windows["Xbox Voice Deck"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["simulation.banner"].exists)
        XCTAssertEqual(app.buttons["routing.startStop"].label, "Start muted")
    }

    func testToneRequiresReviewAndConfirmationThenBypassCancels() {
        launch(); start(); tab("Calibration")
        let confirm = app.buttons["calibration.confirmTone"]
        XCTAssertFalse(confirm.isEnabled)
        toggle("calibration.review").click()
        toggle("calibration.mute").click()
        visible(confirm); XCTAssertTrue(confirm.isEnabled); confirm.click()
        let dialog = app.windows["Xbox Voice Deck"].sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        dialog.buttons["Cancel"].click()
        XCTAssertFalse(app.buttons["calibration.stopTone"].isEnabled)
        confirm.click()
        dialog.buttons["Play for up to 2 seconds"].click()
        XCTAssertTrue(app.buttons["calibration.stopTone"].isEnabled)
        app.buttons["routing.bypass"].click()
        XCTAssertFalse(app.buttons["calibration.stopTone"].isEnabled)
        XCTAssertFalse(confirm.isEnabled, "Tone cancellation must leave Xbox muted")
    }

    func testSavedProfileRequiresReviewAndRestoresMuted() {
        launch(); start(); tab("Calibration")
        let save = app.buttons["calibration.saveProfile"]
        visible(save); save.click()
        let restore = app.buttons["calibration.restoreProfile"]
        visible(restore); XCTAssertFalse(restore.isEnabled)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 1200)
        let review = toggle("calibration.review")
        XCTAssertTrue(review.isHittable); review.click()
        toggle("calibration.mute").click()
        visible(restore); XCTAssertTrue(restore.isEnabled); restore.click()
        waitText("calibration.message", contains: "muted")
        XCTAssertFalse(restore.isEnabled, "Restoring consumes the setup review")
    }

    func testOfflineCheckAndCopiedDiagnosticsAreExplicitlySimulated() {
        launch(); tab("Calibration")
        let check = app.buttons["calibration.offlineCheck"]
        visible(check); check.click()
        waitText("calibration.offlineResult", contains: "Software checks passed")
        tab("Diagnostics")
        app.buttons["diagnostics.copy"].click()
        XCTAssertTrue((NSPasteboard.general.string(forType: .string) ?? "").contains("SIMULATED"))
    }
}
