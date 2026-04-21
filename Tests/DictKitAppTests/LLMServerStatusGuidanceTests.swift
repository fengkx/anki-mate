import XCTest
@testable import DictKitApp
@testable import AnkiMateLLM

final class LLMServerStatusGuidanceTests: XCTestCase {
    func testEndpointsFormatBothPorts() {
        XCTAssertEqual(
            LLMServerStatusDisplay.endpoints(
                ankimateServerPort: 57935,
                llamaServerPort: 61094
            ),
            [
                .init(label: "AnkiMate server", value: "57,935", isAvailable: true),
                .init(label: "llama-server", value: "61,094", isAvailable: true)
            ]
        )
    }

    func testEndpointsKeepBothRowsWhenPortsAreMissing() {
        XCTAssertEqual(
            LLMServerStatusDisplay.endpoints(
                ankimateServerPort: 62030,
                llamaServerPort: nil
            ),
            [
                .init(label: "AnkiMate server", value: "62,030", isAvailable: true),
                .init(label: "llama-server", value: "62,031", isAvailable: false)
            ]
        )
    }

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

    func testMissingModelUsesSetupGuidance() {
        let guidance = LLMServerStatusGuidance.make(
            for: .stopped,
            hasModel: false
        )

        XCTAssertEqual(guidance.statusText, "Model required")
        XCTAssertEqual(guidance.actionButtonTitle, "Download Model")
        XCTAssertTrue(guidance.summary.contains("not set up yet"))
        XCTAssertTrue(guidance.actionHint.contains("Download and select a model"))
    }
}
