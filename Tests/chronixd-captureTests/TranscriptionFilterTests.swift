import XCTest
@testable import chronixd_capture

final class TranscriptionFilterTests: XCTestCase {
    func testDropsEmptyAndPeriodOnlyTranscriptions() {
        XCTAssertNil(normalizedTranscriptionText(""))
        XCTAssertNil(normalizedTranscriptionText(" \n "))
        XCTAssertNil(normalizedTranscriptionText("。"))
        XCTAssertNil(normalizedTranscriptionText(" \n。\n "))
    }

    func testKeepsMeaningfulTranscriptions() {
        XCTAssertEqual(normalizedTranscriptionText(" 本文。\n"), "本文。")
        XCTAssertEqual(normalizedTranscriptionText("？"), "？")
    }
}
