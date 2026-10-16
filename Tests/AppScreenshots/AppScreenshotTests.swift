import XCTest
import UIKit

@MainActor
final class AppScreenshotTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.keefeere.InpuDeck")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch() {
        app.launch()
        // Simulator-only first-use dialogs are not documentation screenshots.
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            if owner.alerts.buttons["OK"].exists { owner.alerts.buttons["OK"].tap() }
            if owner.alerts.buttons["Allow"].exists { owner.alerts.buttons["Allow"].tap() }
        }
        XCTAssertTrue(app.buttons["commandsLayout"].waitForExistence(timeout: 10))
    }

    private func capture(_ name: String) {
        let image = app.screenshot().image
        // Render orientation into pixels, not only PNG/EXIF metadata, so the
        // documentation renders consistently in browsers and Markdown viewers.
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        let attachment = XCTAttachment(image: normalized)
        attachment.name = "docs-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            let list = app.collectionViews.firstMatch
            if app.buttons["commandLegendDone"].exists {
                app.swipeUp() // expand/scroll the presented legend, not its parent form
            } else if list.exists { list.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    func testCaptureProductionApplication() {
        launch()
        capture("commands-portrait")

        app.tabBars.buttons["Input"].tap()
        XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 5))
        capture("input-portrait")

        app.tabBars.buttons["Keyboard"].tap()
        XCTAssertTrue(app.buttons["Change language"].waitForExistence(timeout: 5))
        capture("keyboard-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = expectation(
            for: NSPredicate { [app] _, _ in app.frame.width > app.frame.height },
            evaluatedWith: app)
        wait(for: [landscape], timeout: 5)
        capture("keyboard-landscape")
        app.tabBars.buttons["Tools"].tap()
        XCTAssertTrue(app.buttons["appSettings"].waitForExistence(timeout: 5))
        capture("tools-landscape")

        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        launch()
        app.buttons["appSettings"].tap()
        app.buttons["settingsTabs"].tap()
        let checkbox = app.descendants(matching: .any).matching(identifier: "tabEnabled-commands").firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        capture("tabs-settings-portrait")

        app.terminate()
        launch()
        app.buttons["commandsAdd"].tap()
        let body = app.textViews["commandBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        // iOS may show its one-time swipe-keyboard introduction on first use.
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        let name = app.textFields["commandName"]
        name.tap()
        name.typeText("Find and select")
        app.segmentedControls["commandSyntax"].buttons.element(boundBy: 1).tap()
        body.tap()
        body.typeText("Hello, InpuDeck!<Enter><Ctrl+Home><Shift+End>")
        capture("commands-editor")

        let legend = app.buttons["commandLegend"]
        scrollTo(legend)
        legend.tap()
        XCTAssertTrue(app.buttons["commandLegendDone"].waitForExistence(timeout: 5))
        let functions = app.descendants(matching: .any).matching(identifier: "legend-functions").firstMatch
        scrollTo(functions)
        functions.tap()
        let f12 = app.buttons["legend-key-f12"]
        scrollTo(f12)
        capture("commands-legend")
    }
}
