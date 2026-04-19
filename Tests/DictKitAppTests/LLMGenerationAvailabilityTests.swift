import XCTest
import AnkiMateLLM
@testable import DictKitApp

final class LLMGenerationAvailabilityTests: XCTestCase {
    func testManualActionPromptsWhenModelIsMissing() {
        XCTAssertTrue(
            LLMGenerationAvailability.shouldPromptForManualAction(
                hasModel: false,
                serverState: .stopped
            )
        )
    }

    func testManualActionPromptsWhenServerFailed() {
        XCTAssertTrue(
            LLMGenerationAvailability.shouldPromptForManualAction(
                hasModel: true,
                serverState: .failed("Server binary not found")
            )
        )
    }

    func testManualActionDoesNotPromptWhenServerCanStillLazyStart() {
        XCTAssertFalse(
            LLMGenerationAvailability.shouldPromptForManualAction(
                hasModel: true,
                serverState: .stopped
            )
        )
    }

    func testAvailabilityErrorsAreRecognized() {
        XCTAssertTrue(LLMGenerationAvailability.isAvailabilityError(LLMServiceError.serverNotAvailable))
        XCTAssertTrue(LLMGenerationAvailability.isAvailabilityError(LLMServiceError.modelNotDownloaded))
        XCTAssertTrue(LLMGenerationAvailability.isAvailabilityError(RPCClientError.serverNotRunning))
    }

    func testNonAvailabilityErrorsDoNotPrompt() {
        XCTAssertFalse(LLMGenerationAvailability.isAvailabilityError(LLMServiceError.invalidStructuredOutput("bad output")))
        XCTAssertFalse(LLMGenerationAvailability.isAvailabilityError(RPCClientError.decodingError("bad json")))
    }
}
