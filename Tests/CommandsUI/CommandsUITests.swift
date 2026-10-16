import XCTest
import UIKit

@MainActor
final class CommandsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(expert: Bool, manyCommands: Bool = false, orientation: UIDeviceOrientation = .portrait) {
        XCUIDevice.shared.orientation = orientation
        app.launchArguments = (expert ? ["--expert"] : []) + (manyCommands ? ["--many-commands"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["commandsLayout"].waitForExistence(timeout: 5))
    }

    private func waitFor(_ element: XCUIElement, key: String, value: String) {
        let changed = expectation(
            for: NSPredicate(format: "%K == %@", key, value), evaluatedWith: element)
        wait(for: [changed], timeout: 4)
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testVisibleLayoutShortAndLongPressInBothModes() {
        for expert in [false, true] {
            launch(expert: expert)
            let button = app.buttons["commandsLayout"]
            XCTAssertTrue(button.isHittable, "Floating layout control must be visible")
            XCTAssertFalse(app.staticTexts["Команди"].exists, "No Commands heading or tab caption")
            XCTAssertEqual(button.value as? String, "EN")
            let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft]
            for (index, orientation) in orientations.enumerated() {
                XCUIDevice.shared.orientation = orientation
                let hittable = expectation(
                    for: NSPredicate(format: "hittable == true"), evaluatedWith: button)
                wait(for: [hittable], timeout: 5)
                attachScreenshot("commands-\(expert ? "expert" : "normal")-\(index)")
                if orientation == .portrait {
                    XCTAssertGreaterThan(app.frame.height, app.frame.width)
                } else {
                    XCTAssertGreaterThan(app.frame.width, app.frame.height)
                }
                let reorder = app.buttons["commandsEdit"]
                XCTAssertTrue(reorder.isHittable)
                XCTAssertEqual(reorder.staticTexts.count, 0, "Reorder must be a compact icon")
                XCTAssertGreaterThan(button.frame.midY, app.frame.midY, "Layout control belongs at the bottom")
                XCTAssertLessThan(abs(button.frame.midY - reorder.frame.midY), 8)
                let before = reorder.label
                reorder.tap()
                XCTAssertNotEqual(reorder.label, before, "Reorder button must toggle edit mode")
                reorder.tap()
                XCTAssertEqual(reorder.label, before)
                let center = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                center.tap()
                waitFor(button, key: "value", value: "UA")
                waitFor(app.staticTexts["sentCount"], key: "label", value: String(index + 1))
                center.press(forDuration: 0.8)
                waitFor(button, key: "value", value: "EN")
                XCTAssertEqual(app.staticTexts["sentCount"].label, String(index + 1),
                               "Long press must not send a host shortcut")
            }
            app.terminate()
        }
    }

    private func fixtureRow(_ index: Int) -> XCUIElement {
        let id = "commandRow-" + String(format: "00000000-0000-0000-0000-%012d", index + 1)
        let direct = app.cells[id]
        return direct.exists ? direct : app.cells.containing(.any, identifier: id).firstMatch
    }

    func testManyRowsReorderAndScrollClearOfBottomControls() {
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft] {
            // Launch directly in the target orientation rather than beginning
            // a native reorder drag during a window-rotation transition.
            launch(expert: false, manyCommands: true, orientation: orientation)
            let edit = app.buttons["commandsEdit"]
            let layout = app.buttons["commandsLayout"]
            XCTAssertTrue(edit.isHittable)
            edit.tap()
            let first = fixtureRow(0)
            let second = fixtureRow(1)
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            XCTAssertTrue(second.isHittable)
            attachScreenshot("commands-before-reorder-\(orientation.rawValue)")
            // Move the second row upward, away from the bottom overlay. A drop
            // at the bottom of a row can land on floating controls in landscape.
            let handle = second.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).firstMatch
            XCTAssertLessThan(second.frame.midY, layout.frame.minY)
            if handle.exists { XCTAssertTrue(handle.isHittable) }
            let start = (handle.exists ? handle : second).coordinate(
                withNormalizedOffset: CGVector(dx: handle.exists ? 0.5 : 0.97, dy: 0.5))
            let end = first.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.1))
            start.press(forDuration: 1, thenDragTo: end)
            XCTAssertGreaterThan(first.frame.minY, second.frame.minY,
                                 "Dragging must really change row order, not just the edit label")
            edit.tap()

            let last = fixtureRow(23)
            let add = app.buttons["commandsAdd"]
            for _ in 0..<18 {
                if last.isHittable && add.isHittable && last.frame.maxY < layout.frame.minY { break }
                app.swipeUp()
            }
            XCTAssertTrue(last.isHittable, "Last command must remain reachable")
            XCTAssertTrue(add.isHittable, "Add row must remain reachable")
            XCTAssertLessThan(last.frame.maxY, layout.frame.minY,
                              "Last command must scroll clear of the floating controls")
            XCTAssertTrue(layout.isHittable)
            XCTAssertTrue(edit.isHittable)
            attachScreenshot("commands-last-row-\(orientation.rawValue)")
            app.terminate()
        }
    }

    func testExpertAddIsIconOnlyAndEditorHasNoHelpOrSuccessPreview() {
        launch(expert: true)
        let add = app.buttons["commandsAdd"]
        XCTAssertTrue(add.isHittable)
        XCTAssertEqual(add.staticTexts.count, 0, "Expert Add must be only +")
        add.tap()
        let body = app.descendants(matching: .any).matching(identifier: "commandBody").firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["commandSyntaxHelp"].exists)
        app.segmentedControls["commandSyntax"].buttons.element(boundBy: 1).tap()
        body.tap()
        body.typeText("hello")
        XCTAssertFalse(app.staticTexts["commandSyntaxHelp"].exists)
        XCTAssertFalse(app.staticTexts["commandParseError"].exists)
        XCTAssertFalse(app.staticTexts["Рядок 1"].exists,
                       "Successful parses must not echo a row below the editor")
        attachScreenshot("commands-editor-expert")
    }

    func testNormalEditorKeepsHelpButDoesNotEchoSuccessfulLines() {
        launch(expert: false)
        app.buttons["commandsAdd"].tap()
        XCTAssertTrue(app.staticTexts["commandSyntaxHelp"].waitForExistence(timeout: 5))
        app.segmentedControls["commandSyntax"].buttons.element(boundBy: 1).tap()
        let body = app.descendants(matching: .any).matching(identifier: "commandBody").firstMatch
        body.tap()
        body.typeText("Enter<Enter>")
        XCTAssertFalse(app.staticTexts["commandParseError"].exists)
        XCTAssertFalse(app.staticTexts["Рядок 1"].exists)
        attachScreenshot("commands-editor-normal")
        body.typeText("<Bogus>")
        XCTAssertTrue(app.staticTexts["commandParseError"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Додати"].isEnabled, "Invalid key markers must block saving")
    }
}
