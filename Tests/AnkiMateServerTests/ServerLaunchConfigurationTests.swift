import XCTest
@testable import AnkiMateServer

final class ServerLaunchConfigurationTests: XCTestCase {
    func testParsesPortAndParentProcessID() throws {
        let configuration = try ServerLaunchConfiguration(
            arguments: [
                "AnkiMateServer",
                "0",
                "--parent-pid",
                "4242"
            ]
        )

        XCTAssertEqual(configuration.port, 0)
        XCTAssertEqual(configuration.expectedParentProcessID, 4242)
    }

    func testRejectsMissingParentProcessIDValue() {
        XCTAssertThrowsError(
            try ServerLaunchConfiguration(arguments: ["AnkiMateServer", "--parent-pid"])
        ) { error in
            XCTAssertEqual(error as? ServerLaunchConfigurationError, .missingValue("--parent-pid"))
        }
    }

    func testDetectsParentProcessLossWhenParentPIDChanges() {
        XCTAssertTrue(
            ParentProcessMonitor.hasLostExpectedParent(
                expectedParentProcessID: 4242,
                currentParentProcessID: 1
            )
        )
        XCTAssertFalse(
            ParentProcessMonitor.hasLostExpectedParent(
                expectedParentProcessID: 4242,
                currentParentProcessID: 4242
            )
        )
    }

    func testInferenceEngineThreadSettingsDefaultToGenerationMinusTwoAndBatchEqualsAllCores() {
        let settings = InferenceEngine.resolveThreadSettings(
            environment: [:],
            activeProcessorCount: 8
        )

        XCTAssertEqual(settings.generationThreads, 6)
        XCTAssertEqual(settings.batchThreads, 8)
    }

    func testInferenceEngineThreadSettingsHonorPositiveEnvironmentOverrides() {
        let settings = InferenceEngine.resolveThreadSettings(
            environment: [
                "DICTKIT_LLM_THREADS": "3",
                "DICTKIT_LLM_THREADS_BATCH": "7"
            ],
            activeProcessorCount: 8
        )

        XCTAssertEqual(settings.generationThreads, 3)
        XCTAssertEqual(settings.batchThreads, 7)
    }

    func testInferenceEngineThreadSettingsIgnoreInvalidOverrides() {
        let settings = InferenceEngine.resolveThreadSettings(
            environment: [
                "DICTKIT_LLM_THREADS": "0",
                "DICTKIT_LLM_THREADS_BATCH": "-1"
            ],
            activeProcessorCount: 4
        )

        XCTAssertEqual(settings.generationThreads, 2)
        XCTAssertEqual(settings.batchThreads, 4)
    }
}
