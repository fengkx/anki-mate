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

}
