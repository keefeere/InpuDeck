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
        // Element screenshots can crop a landscape app using portrait bounds.
        // Capture the display, then make its pixel orientation explicit.
        let source = XCUIScreen.main.screenshot().image
        guard let pixels = source.cgImage else { XCTFail("Screenshot has no pixels"); return }
        let landscape = app.frame.width > app.frame.height
        let rawLandscape = pixels.width > pixels.height
        let orientation: UIImage.Orientation
        if rawLandscape == landscape {
            orientation = .up // pixels already match the interface; don't rotate twice
        } else if source.imageOrientation != .up {
            orientation = source.imageOrientation
        } else {
            orientation = XCUIDevice.shared.orientation == .landscapeRight ? .right : .left
        }
        let image = UIImage(cgImage: pixels, scale: 1, orientation: orientation)
        let short = CGFloat(min(pixels.width, pixels.height))
        let long = CGFloat(max(pixels.width, pixels.height))
        let size = landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // size is already in pixels
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
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
        capture("commands-legend-functions")
        app.collectionViews.firstMatch.swipeDown()
        scrollTo(app.buttons["legend-key-home"])
        capture("commands-legend")
    }
}
