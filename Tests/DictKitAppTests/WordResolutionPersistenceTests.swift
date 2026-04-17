import DictKit
import DictKitSystemDictionary
import XCTest
@testable import DictKitApp

final class WordResolutionPersistenceTests: XCTestCase {
    func testPersistedWordRecordRoundTripsResolutionMetadata() {
        let item = WordItem(
            word: "flock",
            sourceForm: "flocked",
            inflectionKind: .pastOrPastParticiple,
            expectedPartOfSpeech: .verb,
            lookupState: .loaded(Self.makeLookupResult(query: "flock"))
        )

        let record = PersistedWordRecord(item: item)
        let restored = record.makeWordItem()

        XCTAssertEqual(record.displayWord, "flock")
        XCTAssertEqual(record.sourceForm, "flocked")
        XCTAssertEqual(record.inflectionKind, .pastOrPastParticiple)
        XCTAssertEqual(record.expectedPartOfSpeech, .verb)
        XCTAssertEqual(restored.word, "flock")
        XCTAssertEqual(restored.sourceForm, "flocked")
        XCTAssertEqual(restored.inflectionKind, .pastOrPastParticiple)
        XCTAssertEqual(restored.expectedPartOfSpeech, .verb)
    }

    private static func makeLookupResult(query: String) -> LookupResult {
        LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: query,
                    pronunciations: [],
                    lexicalEntries: [],
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }
}
