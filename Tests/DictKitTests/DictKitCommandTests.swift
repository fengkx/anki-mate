import XCTest
@testable import DictKit
@testable import DictKitCLI

final class DictKitCommandTests: XCTestCase {
    func testCommandFailureMapsLookupErrorsToRuntimeFailures() {
        XCTAssertEqual(
            DictKitCommand.commandFailure(for: .dictionaryUnavailable("NOAD"))?.errorDescription,
            "Dictionary unavailable: NOAD"
        )
        XCTAssertEqual(
            DictKitCommand.commandFailure(for: .sourceUnavailable)?.errorDescription,
            "The private dictionary source is unavailable on this build."
        )
        XCTAssertEqual(
            DictKitCommand.commandFailure(for: .parseFailed)?.errorDescription,
            "Dictionary content was fetched but could not be parsed."
        )
    }
}
