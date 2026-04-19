import XCTest
@testable import DictKitApp
@testable import AnkiMateLLM

final class LLMServerStatusGuidanceTests: XCTestCase {
    func testMissingBinaryFailureUsesUserFacingRecoveryText() {
        let guidance = LLMServerStatusGuidance.make(for: .failed("Server binary not found"))

        XCTAssertEqual(guidance.statusText, "Local AI components are missing")
        XCTAssertEqual(guidance.actionButtonTitle, "Try Again")
        XCTAssertTrue(guidance.summary.contains("missing the local AI runtime"))
        XCTAssertTrue(guidance.actionHint.contains("Reinstall or update the app"))
        XCTAssertTrue(guidance.actionHint.contains("just build"))
    }

    func testLaunchFailureAvoidsLogFirstGuidance() {
        let guidance = LLMServerStatusGuidance.make(for: .failed("Failed to launch server: permission denied"))

        XCTAssertEqual(guidance.statusText, "Local AI could not start")
        XCTAssertEqual(guidance.actionButtonTitle, "Try Again")
        XCTAssertTrue(guidance.actionHint.contains("restart the app"))
        XCTAssertFalse(guidance.actionHint.lowercased().contains("log"))
    }
}
