import XCTest
import UIKit

@MainActor
final class CommandsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(expert: Bool) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = expert ? ["--expert"] : []
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
            XCTAssertTrue(button.isHittable, "Layout must be visible below the connection header")
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
        body.typeText("Enter")
        XCTAssertFalse(app.staticTexts["commandParseError"].exists)
        XCTAssertFalse(app.staticTexts["Рядок 1"].exists)
        attachScreenshot("commands-editor-normal")
    }
}
