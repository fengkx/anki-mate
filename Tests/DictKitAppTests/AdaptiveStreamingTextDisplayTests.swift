import XCTest
@testable import DictKitApp

final class AdaptiveStreamingRatePolicyTests: XCTestCase {
    func testSpeedIncreasesWithBacklogAndIsClamped() {
        let policy = AdaptiveStreamingRatePolicy()

        XCTAssertGreaterThan(policy.speed(forBacklog: 100), policy.speed(forBacklog: 1))
        XCTAssertEqual(policy.speed(forBacklog: 10_000), 1_800)
        XCTAssertEqual(policy.speed(forBacklog: 0), 0)
    }

    func testSpeedCruisesNearTargetPreviewLead() {
        let policy = AdaptiveStreamingRatePolicy()

        XCTAssertLessThan(policy.speed(forBacklog: 60), policy.speed(forBacklog: 180))
        XCTAssertEqual(policy.speed(forBacklog: 180), 360, accuracy: 0.001)
        XCTAssertGreaterThan(policy.speed(forBacklog: 420), policy.speed(forBacklog: 180))
    }

    func testPreviewWindowIsBounded() {
        let policy = AdaptiveStreamingRatePolicy()

        XCTAssertEqual(policy.previewWindow(forBacklog: 1), 96)
        XCTAssertEqual(policy.previewWindow(forBacklog: 100), 100)
        XCTAssertEqual(policy.previewWindow(forBacklog: 1_000), 360)
    }

    func testPunctuationPauseOnlyAppliesToSmallBacklog() {
        let policy = AdaptiveStreamingRatePolicy()

        XCTAssertEqual(policy.punctuationPause(after: "，", backlog: 12), 0.008)
        XCTAssertEqual(policy.punctuationPause(after: "。", backlog: 12), 0.016)
        XCTAssertEqual(policy.punctuationPause(after: "。", backlog: 36), 0)
        XCTAssertEqual(policy.punctuationPause(after: "a", backlog: 12), 0)
    }
}

@MainActor
final class AdaptiveStreamingTextDisplayTests: XCTestCase {
    func testTargetGrowthShowsPreviewImmediatelyThenCommitsOverTime() {
        let display = AdaptiveStreamingTextDisplay(startsTaskAutomatically: false)

        display.setTarget("Hello world")

        XCTAssertEqual(display.committedText, "")
        XCTAssertEqual(display.previewText, "Hello world")

        display.advance(elapsed: 0.1)

        XCTAssertFalse(display.committedText.isEmpty)
        XCTAssertTrue("Hello world".hasPrefix(display.committedText))
        XCTAssertEqual(display.committedText + display.previewText, "Hello world")
    }

    func testPreviewLengthDoesNotExceedWindow() {
        let display = AdaptiveStreamingTextDisplay(startsTaskAutomatically: false)
        let text = String(repeating: "a", count: 300)

        display.setTarget(text)

        XCTAssertEqual(display.committedText, "")
        XCTAssertEqual(display.previewText.count, 300)
    }

    func testAdvancePreservesCharacterBoundaries() {
        let display = AdaptiveStreamingTextDisplay(startsTaskAutomatically: false)

        display.setTarget("你🙂好")
        display.advance(elapsed: 0.03)

        XCTAssertTrue(["", "你", "你🙂", "你🙂好"].contains(display.committedText))
        XCTAssertEqual(display.committedText + display.previewText, "你🙂好")
    }

    func testNonPrefixTargetResetClearsCommittedText() {
        let display = AdaptiveStreamingTextDisplay(startsTaskAutomatically: false)

        display.setTarget("abcdef")
        display.advance(elapsed: 0.2)
        XCTAssertFalse(display.committedText.isEmpty)

        display.setTarget("XYZ")

        XCTAssertEqual(display.committedText, "")
        XCTAssertEqual(display.previewText, "XYZ")
    }

    func testCommittedTextNeverExceedsTarget() {
        let display = AdaptiveStreamingTextDisplay(startsTaskAutomatically: false)

        display.setTarget("short")
        display.advance(elapsed: 10)

        XCTAssertEqual(display.committedText, "short")
        XCTAssertEqual(display.previewText, "")
        XCTAssertEqual(display.committedCharacterCount, display.targetCharacterCount)
    }
}
