import XCTest
import AnkiMateLLM
@testable import DictKitApp

final class LLMGenerationAvailabilityTests: XCTestCase {
    func testResolvedStateIsNoModelConfiguredWhenModelIsMissing() {
        XCTAssertEqual(
            LLMGenerationAvailability.resolvedState(
                hasModel: false,
                serverState: .stopped
            ),
            .noModelConfigured
        )
    }

    func testResolvedStateIsServiceIdleWhenModelExistsButServerIsStopped() {
        XCTAssertEqual(
            LLMGenerationAvailability.resolvedState(
                hasModel: true,
                serverState: .stopped
            ),
            .modelAvailableServiceIdle
        )
    }

    func testResolvedStateDetectsMissingRuntimeFromFailedServerState() {
        XCTAssertEqual(
            LLMGenerationAvailability.resolvedState(
                hasModel: true,
                serverState: .failed("Server binary not found")
            ),
            .runtimeMissing
        )
    }

    func testResolvedStateDetectsServerStartFailure() {
        XCTAssertEqual(
            LLMGenerationAvailability.resolvedState(
                hasModel: true,
                serverState: .failed("Failed to launch server: permission denied")
            ),
            .serviceFailedToStart
        )
    }

    func testResolvedStateTreatsServerNotRunningErrorAsTemporaryWhenModelExists() {
        XCTAssertEqual(
            LLMGenerationAvailability.resolvedState(
                hasModel: true,
                serverState: .running(port: 8080),
                error: RPCClientError.serverNotRunning
            ),
            .temporarilyUnavailable
        )
    }

    func testExamplesActionMessageExplainsHowToRecoverWhenNoModelConfigured() {
        XCTAssertEqual(
            LLMGenerationAvailability.actionMessage(
                for: .examples,
                state: .noModelConfigured
            ),
            "Set up local AI in AI Settings to generate examples."
        )
    }

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
