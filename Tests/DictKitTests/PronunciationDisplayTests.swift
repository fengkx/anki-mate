import DictKit
import XCTest

final class PronunciationDisplayTests: XCTestCase {
    func testDisplayNotationWrapsRealIPAWithDelimitersOnlyAtRenderTime() {
        let pronunciation = Pronunciation(dialect: "AmE", ipa: "ˈdɪkʃəˌnɛri", respelling: nil)

        XCTAssertEqual(pronunciation.displayNotation, "ˈdɪkʃəˌnɛri")
        XCTAssertTrue(pronunciation.usesIPADelimitersForDisplay)
    }

    func testDisplayNotationKeepsRespellingOutOfFakeIPASlashes() {
        let pronunciation = Pronunciation(dialect: "AmE", ipa: "käləˈkāSHən", respelling: "käləˈkāSHən")

        XCTAssertEqual(pronunciation.displayNotation, "käləˈkāshən")
        XCTAssertFalse(pronunciation.usesIPADelimitersForDisplay)
    }
}
