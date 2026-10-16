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
            XCTAssertTrue(app.tabBars.buttons["Команди"].exists,
                          "Commands must keep its accessible tab name in both modes")
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
                // Native reorder interactions are exercised separately by
                // the multi-row test, without mixing its animations into taps.
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

    private func settingsRow(_ tab: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: "tabTitle-" + tab).firstMatch
    }

    private func enabledControl(_ tab: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tabEnabled-" + tab).firstMatch
    }

    private func openTabSettings() {
        app.buttons["openTabSettings"].tap()
        attachScreenshot("tab-settings-open")
        XCTAssertTrue(enabledControl("input").waitForExistence(timeout: 5))
    }

    private func closeTabSettings() {
        let dismiss = app.buttons["dismissTabSettings"]
        dismiss.tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: dismiss)
        wait(for: [closed], timeout: 5)
        XCTAssertTrue(app.buttons["openTabSettings"].waitForExistence(timeout: 5))
    }

    private func edgeSwipeForward() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.4))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testTabVisibilityOrderPersistenceAndSwipeNavigation() {
        launch(expert: false)
        XCTAssertTrue(app.tabBars.buttons["Команди"].exists)
        openTabSettings()
        let keyboard = enabledControl("keyboard")
        let before = keyboard.value as? String
        keyboard.tap()
        XCTAssertNotEqual(keyboard.value as? String, before)

        let commands = settingsRow("commands")
        let input = settingsRow("input")
        let handle = commands.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).firstMatch
        XCTAssertTrue(handle.exists)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1, thenDragTo: input.coordinate(
                withNormalizedOffset: CGVector(dx: 0.95, dy: 0.1)))
        XCTAssertLessThan(commands.frame.minY, input.frame.minY, "Tab rows must really reorder")
        attachScreenshot("tab-settings-reordered")
        closeTabSettings()
        let expected = ["Команди", "Ввід", "Інструменти"]
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), expected)
        XCTAssertEqual(app.staticTexts["selectedPage"].label, "commands",
                       "Reordering must preserve the selected page identity")

        app.terminate()
        app.launchArguments = ["--preserve-tabs"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Команди"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), expected)
        XCTAssertEqual(app.staticTexts["selectedPage"].label, "commands")
        edgeSwipeForward()
        waitFor(app.staticTexts["selectedPage"], key: "label", value: "input")
        edgeSwipeForward()
        waitFor(app.staticTexts["selectedPage"], key: "label", value: "tools")
    }

    func testHidingCurrentTabFallsBackAndLastTabCannotBeDisabled() {
        launch(expert: false)
        openTabSettings()
        for tab in ["commands", "keyboard", "tools"] {
            enabledControl(tab).tap()
        }
        XCTAssertFalse(enabledControl("input").isEnabled,
                       "The final active tab checkbox must not be switchable")
        attachScreenshot("tab-settings-last-enabled")
        closeTabSettings()
        XCTAssertEqual(app.tabBars.buttons.count, 1)
        XCTAssertEqual(app.staticTexts["selectedPage"].label, "input",
                       "Hiding current Commands must choose a visible page")
        openTabSettings()
        enabledControl("commands").tap()
        closeTabSettings()
        XCTAssertTrue(app.tabBars.buttons["Команди"].exists)
        let commands = app.tabBars.buttons["Команди"]
        commands.tap()
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: commands)
        wait(for: [selected], timeout: 5)
        waitFor(app.staticTexts["selectedPage"], key: "label", value: "commands")
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
        XCTAssertFalse(app.buttons["commandLegend"].exists)
        app.segmentedControls["commandSyntax"].buttons.element(boundBy: 1).tap()
        body.tap()
        body.typeText("hello")
        XCTAssertFalse(app.buttons["commandLegend"].exists)
        XCTAssertFalse(app.staticTexts["commandParseError"].exists)
        XCTAssertFalse(app.staticTexts["Рядок 1"].exists,
                       "Successful parses must not echo a row below the editor")
        attachScreenshot("commands-editor-expert")
    }

    private func newMixedEditor() -> XCUIElement {
        launch(expert: false)
        app.buttons["commandsAdd"].tap()
        let body = app.textViews["commandBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        app.segmentedControls["commandSyntax"].buttons.element(boundBy: 1).tap()
        body.tap()
        return body
    }

    private func openLegend() {
        let link = app.buttons["commandLegend"]
        for _ in 0..<4 {
            if link.exists && link.isHittable { break }
            let form = app.collectionViews.firstMatch
            if form.exists { form.swipeUp() } else { app.swipeUp() }
        }
        link.tap()
        XCTAssertTrue(app.buttons["commandLegendDone"].waitForExistence(timeout: 5))
    }

    private func insertLegendEntry(_ identifier: String) {
        let entry = app.buttons[identifier]
        for _ in 0..<6 {
            if entry.exists && entry.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(entry.isHittable)
        entry.tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"),
                                 evaluatedWith: app.buttons["commandLegendDone"])
        wait(for: [closed], timeout: 5)
    }

    func testCommandNameAndBodyCanExchangeKeyboardFocus() {
        launch(expert: false)
        app.buttons["commandsAdd"].tap()
        let body = app.textViews["commandBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        let name = app.textFields["commandName"]
        name.tap()
        name.typeText("Named")
        XCTAssertEqual(name.value as? String, "Named")
        body.tap()
        body.typeText("Body")
        name.tap()
        name.typeText(" command")
        XCTAssertEqual(name.value as? String, "Named command")
        XCTAssertEqual(body.value as? String, "Body")
    }

    func testLegendModifierTemplateRestoresCaretBeforeClosingBracket() {
        let body = newMixedEditor()
        body.typeText("abc")
        openLegend()
        attachScreenshot("command-legend")
        insertLegendEntry("legend-modifier-ctrl")
        waitFor(body, key: "value", value: "abc<Ctrl+>")
        openLegend()
        insertLegendEntry("legend-modifier-shift")
        waitFor(body, key: "value", value: "abc<Ctrl+Shift+>")
        openLegend()
        insertLegendEntry("legend-key-right")
        waitFor(body, key: "value", value: "abc<Ctrl+Shift+Right>")
        // Completed key insertion leaves the cursor after the original closing
        // bracket, so ordinary text can continue without tapping the editor.
        body.typeText("!")
        waitFor(body, key: "value", value: "abc<Ctrl+Shift+Right>!")
        XCTAssertFalse(app.staticTexts["commandParseError"].exists)
    }

    func testLegendFunctionAndNavigationGridsInsertOnlySelectedKey() {
        let body = newMixedEditor()
        openLegend()
        let functions = app.descendants(matching: .any).matching(identifier: "legend-functions").firstMatch
        for _ in 0..<6 {
            if functions.exists && functions.isHittable { break }
            app.swipeUp()
        }
        functions.tap()
        XCTAssertTrue(app.buttons["legend-key-f1"].waitForExistence(timeout: 5))
        attachScreenshot("command-legend-functions")
        insertLegendEntry("legend-key-f12")
        waitFor(body, key: "value", value: "<F12>")
        openLegend()
        insertLegendEntry("legend-key-home")
        waitFor(body, key: "value", value: "<F12><Home>")
    }

    func testLegendReplacesNativeSelectionInsteadOfAppending() {
        let body = newMixedEditor()
        body.typeText("replace")
        // Double-tap inside the only word to select it with native UITextView.
        body.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.09)).doubleTap()
        openLegend()
        insertLegendEntry("legend-key-enter")
        waitFor(body, key: "value", value: "<Enter>")
        body.typeText("!")
        waitFor(body, key: "value", value: "<Enter>!")
    }

    func testNormalEditorKeepsHelpButDoesNotEchoSuccessfulLines() {
        launch(expert: false)
        app.buttons["commandsAdd"].tap()
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
