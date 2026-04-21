import XCTest
@testable import DictKitApp

final class CardPreviewViewTests: XCTestCase {
    func testCardPreviewAIPanelLayoutRestoresPersistedHeightWithinBounds() {
        XCTAssertEqual(
            CardPreviewAIPanelLayout.restoredHeight(
                fromPersistedRatio: 0.5,
                availableHeight: 800,
                minHeight: 180,
                minTopHeight: 96
            ),
            400
        )
    }

    func testCardPreviewAIPanelLayoutClampsRestoredHeightToLeavePreviewVisible() {
        XCTAssertEqual(
            CardPreviewAIPanelLayout.restoredHeight(
                fromPersistedRatio: 0.98,
                availableHeight: 600,
                minHeight: 180,
                minTopHeight: 96
            ),
            504
        )
    }

    func testCardPreviewAIPanelLayoutPersistsRatioUsingClampedRange() {
        XCTAssertEqual(
            CardPreviewAIPanelLayout.persistedRatio(
                forHeight: 120,
                availableHeight: 1_000
            ),
            0.2,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            CardPreviewAIPanelLayout.persistedRatio(
                forHeight: 900,
                availableHeight: 1_000
            ),
            0.9,
            accuracy: 0.000_1
        )
    }

    func testCardPreviewHTMLReloadPolicySkipsReloadWhenMarkupDidNotChange() {
        XCTAssertFalse(
            CardPreviewHTMLReloadPolicy.shouldReload(
                previousHTML: "<p>apple</p>",
                nextHTML: "<p>apple</p>"
            )
        )
    }

    func testCardPreviewHTMLReloadPolicyReloadsWhenMarkupChanges() {
        XCTAssertTrue(
            CardPreviewHTMLReloadPolicy.shouldReload(
                previousHTML: "<p>apple</p>",
                nextHTML: "<p>banana</p>"
            )
        )
        XCTAssertTrue(
            CardPreviewHTMLReloadPolicy.shouldReload(
                previousHTML: nil,
                nextHTML: "<p>apple</p>"
            )
        )
    }
}
