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

    func testSwipeOnASwipeableKeyMovesThePointerWithoutLeavingTheKeyHeld() {
        let key = app.buttons["swipeableKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        let center = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // A tap is still a key press.
        center.tap()
        assertCounts("swipe", "1:1:0")

        // A stationary hold is still a key press.
        center.press(forDuration: 0.8)
        assertCounts("swipe", "2:2:0")

        // Movement below the swipe threshold stays a key press and moves nothing.
        center.press(forDuration: 0.3, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 8)))
        assertCounts("swipe", "3:3:0")

        // A drag past the threshold becomes pointer control. Whatever the touch
        // timing, the key must not be left held and the pointer must move.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 140, dy: 0)))
        let swipe = expectation(for: NSPredicate(format: "label BEGINSWITH '3:' OR label BEGINSWITH '4:'"), evaluatedWith: app.staticTexts["swipeCounts"])
        wait(for: [swipe], timeout: 3)
        let counts = fields("swipe")
        XCTAssertEqual(counts.count, 3)
        XCTAssertEqual(counts[0], counts[1], "A swipe never leaves a key-down unreleased")
        XCTAssertGreaterThan(counts[2], 0, "A swipe must emit pointer movement")

        // Repeating the swipe keeps emitting relative deltas.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -140, dy: 0)))
        let again = expectation(for: NSPredicate(format: "label != %@", "3:3:1"), evaluatedWith: app.staticTexts["swipeCounts"])
        wait(for: [again], timeout: 3)
        let repeated = fields("swipe")
        XCTAssertEqual(repeated[0], repeated[1], "Every key-down is paired with a release")
        XCTAssertGreaterThan(repeated[2], counts[2], "The second swipe moved the pointer again")
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
