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

        // A drift between the tap tolerance and the swipe threshold is a lost
        // swipe attempt, not a swallowed keystroke: the tap goes out on lift.
        center.press(forDuration: 0.3, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 16)))
        assertCounts("swipe", "4:4:0")

        // A drag past the threshold becomes pointer control and must not type.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 140, dy: 0)))
        let moved = expectation(
            for: NSPredicate(format: "label BEGINSWITH '4:4:'"),
            evaluatedWith: app.staticTexts["swipeCounts"]
        )
        wait(for: [moved], timeout: 3)
        let afterSwipe = fields("swipe")
        XCTAssertEqual(afterSwipe.count, 3)
        XCTAssertEqual(afterSwipe[0], 4, "A swipe must not send a key-down the host would keep")
        XCTAssertEqual(afterSwipe[1], 4, "A swipe must not release a key it never pressed")
        XCTAssertGreaterThan(afterSwipe[2], 0, "A swipe must emit pointer movement")

        // Dragging back keeps pointing and keeps typing nothing.
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: -140, dy: 0)))
        let movedBack = expectation(
            for: NSPredicate(format: "label BEGINSWITH '4:4:'"),
            evaluatedWith: app.staticTexts["swipeCounts"]
        )
        wait(for: [movedBack], timeout: 3)
        XCTAssertGreaterThan(fields("swipe")[2], afterSwipe[2], "The second swipe moved the pointer again")
        XCTAssertEqual(fields("swipe")[0], 4, "A swipe never types")
    }

    func testLongKeyDragContinuesPastTheEdgeNavigationThreshold() {
        let key = app.buttons["swipeableKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        let center = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 140, dy: 0)))
        let values = app.staticTexts["pointerDistance"].label.split(separator: ":").compactMap { Int($0) }
        XCTAssertEqual(values.count, 2)
        guard values.count == 2 else { return }
        XCTAssertGreaterThan(values[0], 150, "Most of the 140-point drag must reach the pointer")
        XCTAssertEqual(values[1], 0, "A drag starting in the middle must not navigate tabs")
        XCTAssertEqual(fields("swipe")[0], 0, "Pointer drag must not type a key")
    }

    func testEdgeNavigationWorksInBothDirectionsAndRejectsShortDrags() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 15, dy: 0))
        let right = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -15, dy: 0))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 50, dy: 0)))
        assertCounts("navigation", "0:0")
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 150, dy: 0)))
        assertCounts("navigation", "1:-1")
        right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: -150, dy: 0)))
        assertCounts("navigation", "2:1")
    }

    func testEdgeNavigationYieldsToASwipeableKeyAtTheScreenEdge() {
        // A swipe that starts on the keyboard key touching the left edge
        // belongs to the keyboard: it must drive the pointer and must never
        // navigate the tab behind it, no matter how far it travels.
        let key = app.buttons["edgeSwipeableKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch

        // The navigation pan only claims touches inside a 28-point band at the
        // window edge, so the fixture is worthless unless its touch really sits
        // in that band. Without this, a layout change would quietly turn the
        // test into "a middle-of-screen drag does not navigate".
        let center = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let startFromWindowLeft = key.frame.midX - window.frame.minX
        XCTAssertLessThanOrEqual(startFromWindowLeft, 28,
                                 "The fixture key must sit inside the pan's edge band")

        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 140, dy: 0)))

        let moved = expectation(
            for: NSPredicate(format: "label != '0:0:0'"),
            evaluatedWith: app.staticTexts["swipeCounts"]
        )
        wait(for: [moved], timeout: 3)
        XCTAssertEqual(fields("edge").prefix(2), [0, 0], "The edge key swipe must not type")
        assertCounts("navigation", "0:0")
        XCTAssertGreaterThan(fields("swipe")[2], 0, "The edge key swipe still moves the pointer")
    }

    func testEdgeNavigationIsBlockedWhileAModalCoverIsPresented() {
        app.buttons["showModalButton"].tap()
        XCTAssertTrue(app.staticTexts["modalContent"].waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 15, dy: 0))
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 150, dy: 0)))
        assertCounts("navigation", "0:0")

        // Navigation resumes as soon as the cover is dismissed.
        app.buttons["closeModalButton"].tap()
        let dismissed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.staticTexts["modalContent"]
        )
        wait(for: [dismissed], timeout: 5)
        left.press(forDuration: 0.05, thenDragTo: left.withOffset(CGVector(dx: 150, dy: 0)))
        assertCounts("navigation", "1:-1")
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
