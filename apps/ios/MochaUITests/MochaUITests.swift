import XCTest

final class MochaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStartsWithAnHonestEmptySessionsState() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["No Sessions"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Pair a computer to see and resume its durable terminal sessions."].exists)
    }
}
