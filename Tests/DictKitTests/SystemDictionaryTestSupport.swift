import XCTest
@testable import DictKit
@testable import DictKitSystemDictionary

enum SystemDictionaryTestSupport {
    static func requirePublicLookup(
        for term: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let client = SystemDictionaryClient()
        guard client.lookupDefinition(for: term) != nil else {
            throw XCTSkip("System dictionary public lookup is unavailable for '\(term)' in this test environment.")
        }
    }

    static func requirePublicLookups(
        for terms: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if let missing = terms.first(where: { SystemDictionaryClient().lookupDefinition(for: $0) == nil }) {
            throw XCTSkip("System dictionary public lookup is unavailable for '\(missing)' in this test environment.")
        }
    }

    static func requireAutomaticLookup(
        for term: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        do {
            _ = try SystemDictionaryClient().lookup(term, source: .automatic, includeSource: false)
        } catch LookupError.notFound {
            throw XCTSkip("Automatic system dictionary lookup is unavailable for '\(term)' in this test environment.")
        }
    }

    static func requireAutomaticLookups(
        for terms: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for term in terms {
            do {
                _ = try SystemDictionaryClient().lookup(term, source: .automatic, includeSource: false)
            } catch LookupError.notFound {
                throw XCTSkip("Automatic system dictionary lookup is unavailable for '\(term)' in this test environment.")
            }
        }
    }

    static func requirePrivateHTMLLookup(
        for term: String,
        dictionaryName: String = SystemDictionaryClient.defaultDictionaryName,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let client = SystemDictionaryClient()
        guard client.lookupHTML(for: term, dictionaryName: dictionaryName) != nil else {
            throw XCTSkip("Private HTML dictionary lookup is unavailable for '\(term)' in this test environment.")
        }
    }
}
