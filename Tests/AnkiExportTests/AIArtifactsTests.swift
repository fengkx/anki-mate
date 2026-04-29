import DictKitAnkiExport
import Foundation
import XCTest

final class AIArtifactsTests: XCTestCase {
    func testUnifiedSchemaDecodesExampleTranslationWithoutMutatingText() throws {
        let artifacts = try JSONDecoder().decode(
            AIArtifacts.self,
            from: Data(
                """
                {
                  "schemaVersion": 4,
                  "exampleSentences": {
                    "accepted": [
                      {
                        "text": "Accepted example.",
                        "translation": "示例句"
                      }
                    ]
                  }
                }
                """.utf8
            )
        )

        let accepted = try XCTUnwrap(artifacts.exampleSentences.accepted)
        XCTAssertEqual(accepted.count, 1)
        let artifact = accepted[0]
        XCTAssertEqual(artifact.text, "Accepted example.")
        XCTAssertEqual(artifact.translation, "示例句")
    }

    func testLegacySchemaStillStabilizesExampleTranslationFromText() throws {
        let artifacts = try JSONDecoder().decode(
            AIArtifacts.self,
            from: Data(
                """
                {
                  "schemaVersion": 1,
                  "exampleSentences": {
                    "accepted": [
                      {
                        "text": "Before the meeting — 会前准备",
                        "translation": "stale translation"
                      },
                      {
                        "text": "After the review",
                        "translation": "复盘后"
                      }
                    ]
                  }
                }
                """.utf8
            )
        )

        let accepted = try XCTUnwrap(artifacts.exampleSentences.accepted)
        XCTAssertEqual(accepted.map(\.text), ["Before the meeting — 会前准备", "After the review — 复盘后"])
        XCTAssertEqual(accepted.map(\.translation), ["会前准备", "复盘后"])
    }
}
