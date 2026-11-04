import XCTest

@MainActor
final class PressActionsUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func assertCounts(_ name: String, _ counts: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = app.staticTexts[name + "Counts"]
        let correct = expectation(for: NSPredicate(format: "label == %@", counts), evaluatedWith: label)
        wait(for: [correct], timeout: 3)
        XCTAssertEqual(label.label, counts, file: file, line: line)
    }

    private func fields(_ name: String) -> [Int] {
        app.staticTexts[name + "Counts"].label.split(separator: ":").map { Int($0) ?? -1 }
    }

    func testShortThenLongThenShortForBothButtonShapes() {
        for name in ["language", "orientation"] {
            let button = app.buttons[name + "Button"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            // Coordinates synthesize real touch sequences, rather than invoking
            // the accessibility action or calling an action closure directly.
            let center = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.tap()
            assertCounts(name, "1:0")
            center.press(forDuration: 0.8)
            assertCounts(name, "1:1")
            center.tap()
            assertCounts(name, "2:1")
            center.press(forDuration: 0.8)
            assertCounts(name, "2:2")
        }
    }

    func testDragOutAndDisabledButtonsDoNotActivate() {
        for name in ["language", "orientation"] {
            let center = app.buttons[name + "Button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -100)))
            assertCounts(name, "0:0")
        }
        app.buttons["disableControls"].tap()
        let disabled = expectation(for: NSPredicate(format: "label == 'disabled'"), evaluatedWith: app.staticTexts["enabledState"])
        wait(for: [disabled], timeout: 3)
        for name in ["language", "orientation"] {
            XCTAssertFalse(app.buttons[name + "Button"].isEnabled)
            let center = app.buttons[name + "Button"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.tap()
            center.press(forDuration: 0.8)
            assertCounts(name, "0:0")
        }
    }

    func testKeyDragsOnASwipeableKeyMoveThePointerWithoutTyping() {
        let key = app.buttons["swipeableKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        let center = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // A tap is still a key press.
        center.tap()
        assertCounts("swipe", "1:1:0")

        // A stationary hold is still a key press.
        center.press(forDuration: 0.8)
        assertCounts("swipe", "2:2:0")

        // A drift below the swipe threshold stays a key press and moves nothing.
        center.press(forDuration: 0.3, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 8)))
        assertCounts("swipe", "3:3:0")

        // A drag past the threshold becomes pointer control and must not type.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 140, dy: 0)))
        let moved = expectation(
            for: NSPredicate(format: "label BEGINSWITH '3:3:'"),
            evaluatedWith: app.staticTexts["swipeCounts"]
        )
        wait(for: [moved], timeout: 3)
        let afterSwipe = fields("swipe")
        XCTAssertEqual(afterSwipe.count, 3)
        XCTAssertEqual(afterSwipe[0], 3, "A swipe must not send a key-down the host would keep")
        XCTAssertEqual(afterSwipe[1], 3, "A swipe must not release a key it never pressed")
        XCTAssertGreaterThan(afterSwipe[2], 0, "A swipe must emit pointer movement")

        // Dragging back keeps pointing and keeps typing nothing.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -140, dy: 0)))
        let movedBack = expectation(
            for: NSPredicate(format: "label BEGINSWITH '3:3:'"),
            evaluatedWith: app.staticTexts["swipeCounts"]
        )
        wait(for: [movedBack], timeout: 3)
        XCTAssertGreaterThan(fields("swipe")[2], afterSwipe[2], "The second swipe moved the pointer again")
        XCTAssertEqual(fields("swipe")[0], 3, "A swipe never types")
    }

    func testAHeldKeyThatTurnsIntoASwipeIsReleasedWithoutStayingHeld() {
        let center = app.buttons["swipeableKey"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // A stationary hold past the commit delay is a deliberate key press. When
        // the finger then drags, the held key must be released instead of staying
        // down for the rest of the session.
        center.press(forDuration: 0.8, thenDragTo: center.withOffset(CGVector(dx: 140, dy: 0)))
        let released = expectation(
            for: NSPredicate(format: "label BEGINSWITH '1:1:'"),
            evaluatedWith: app.staticTexts["swipeCounts"]
        )
        wait(for: [released], timeout: 3)
        let counts = fields("swipe")
        XCTAssertEqual(counts[0], 1, "The committed hold sent exactly one key-down")
        XCTAssertEqual(counts[1], 1, "Starting the swipe released the held key")
        XCTAssertGreaterThan(counts[2], 0, "The drag still moved the pointer")
    }

    func testClickZonesPressAndReleaseMouseButtons() {
        for name in ["leftClickZone", "rightClickZone"] {
            let zone = app.buttons[name]
            XCTAssertTrue(zone.waitForExistence(timeout: 5))
            let center = zone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.tap()
        }
        assertCounts("click", "1:1:1:1")

        // Holding a zone keeps the button down and releases it on lift.
        app.buttons["leftClickZone"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.7)
        assertCounts("click", "2:2:1:1")
    }
}
