import XCTest

#if canImport(DictKitSystemDictionary)
@testable import DictKitSystemDictionary

final class SystemDictionaryIntegrationTests: XCTestCase {
    func testAutomaticLookupReturnsStructuredEntries() throws {
        let client = SystemDictionaryClient()
        let result = try client.lookup("apple", source: .automatic, includeSource: false)

        XCTAssertEqual(result.query, "apple")
        XCTAssertFalse(result.entries.isEmpty)
        XCTAssertFalse(result.entries[0].lexicalEntries.isEmpty || result.entries[0].phraseGroups.isEmpty && result.entries[0].notes.isEmpty)
    }
}
#else
final class SystemDictionaryIntegrationTests: XCTestCase {
    func testSystemDictionaryModuleIsOptional() {
        XCTAssertTrue(true)
    }
}
#endif
