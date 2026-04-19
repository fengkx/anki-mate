import Foundation
import XCTest
@testable import DictKitApp

@MainActor
final class HelpCenterStateTests: XCTestCase {
    func testFirstLaunchPresentsGuideAndMarksItSeen() {
        let defaults = makeDefaults()
        let helpCenter = HelpCenterState(defaults: defaults)

        helpCenter.presentGuideIfNeededOnFirstLaunch()

        XCTAssertTrue(helpCenter.isGuidePresented)
        XCTAssertEqual(defaults.object(forKey: HelpCenterState.hasSeenGuideKey) as? Bool, true)
    }

    func testSeenGuideDoesNotAutoPresentAgain() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: HelpCenterState.hasSeenGuideKey)
        let helpCenter = HelpCenterState(defaults: defaults)

        helpCenter.presentGuideIfNeededOnFirstLaunch()

        XCTAssertFalse(helpCenter.isGuidePresented)
    }

    func testGuideCanBeReopenedAfterDismiss() {
        let defaults = makeDefaults()
        let helpCenter = HelpCenterState(defaults: defaults)

        helpCenter.presentGuideIfNeededOnFirstLaunch()
        helpCenter.dismissGuide()
        helpCenter.presentGuide()

        XCTAssertTrue(helpCenter.isGuidePresented)
    }

    func testHelpWindowIdentifierIsStable() {
        XCTAssertEqual(AppWindowIDs.help, "ankimate-help")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HelpCenterStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
