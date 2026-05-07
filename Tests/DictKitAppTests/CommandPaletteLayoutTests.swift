import XCTest
@testable import DictKitApp

final class CommandPaletteLayoutTests: XCTestCase {
    func testSearchFieldUsesRelaxedModalSpacing() {
        let metrics = CommandPaletteLayoutMetrics.default

        XCTAssertEqual(metrics.searchFieldHeight, 50)
        XCTAssertEqual(metrics.searchFieldFontSize, 16)
        XCTAssertEqual(metrics.searchFieldTopPadding, 20)
        XCTAssertEqual(metrics.searchFieldBottomPadding, 16)
    }

    func testRowsAndFooterFollowSameVerticalRhythm() {
        let metrics = CommandPaletteLayoutMetrics.default

        XCTAssertEqual(metrics.sectionSpacing, 14)
        XCTAssertEqual(metrics.rowVerticalPadding, 14)
        XCTAssertEqual(metrics.footerVerticalPadding, 14)
        XCTAssertEqual(metrics.resultsBottomPadding, 10)
    }
}
