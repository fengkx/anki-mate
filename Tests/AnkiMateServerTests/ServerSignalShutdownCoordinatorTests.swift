import XCTest
@testable import AnkiMateServer

final class ServerSignalShutdownCoordinatorTests: XCTestCase {
    func testSignalHandlerRunsShutdownOnlyOnce() {
        var shutdownCount = 0
        let coordinator = ServerSignalShutdownCoordinator(
            signalNumbers: [],
            shutdown: {
                shutdownCount += 1
            }
        )

        coordinator.handleSignalForTesting()
        coordinator.handleSignalForTesting()

        XCTAssertEqual(shutdownCount, 1)
    }
}
