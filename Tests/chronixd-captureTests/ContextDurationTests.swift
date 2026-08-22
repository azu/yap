import XCTest
@testable import chronixd_capture

final class ContextDurationTests: XCTestCase {
    func testParseDurationSupportsDays() throws {
        XCTAssertEqual(try Context.parseDuration("7d"), 7 * 86_400)
        XCTAssertEqual(try Context.parseDuration("1d12h"), 36 * 3_600)
    }

    func testHelpExplainsBrowserURLAndDetailOutput() {
        let help = Context.helpMessage(columns: 120)

        XCTAssertTrue(help.contains("browser URL when available"))
        XCTAssertTrue(help.contains("Add screenshot and camera image paths and availability."))
        XCTAssertTrue(help.contains("Use --schema for the complete field list."))
    }
}
