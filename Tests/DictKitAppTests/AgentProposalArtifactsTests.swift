import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import DictKitAnkiExport

final class AgentProposalArtifactsTests: XCTestCase {
    func testPreviewProjectionReplacesAcceptedExample() throws {
        let baseline = AIArtifacts(
            exampleSentences: .init(
                accepted: [
                    ExampleSentenceArtifact(text: "I ate an apple."),
                    ExampleSentenceArtifact(text: "She packed an apple in his lunch.")
                ]
            )
        )
        let proposal = ProposalRecord(
            kind: .example,
            operation: .replace(targetID: "ex-2"),
            payloadJSON: #"{"text":"Apple stock fell sharply after earnings.","translation":"苹果公司财报后股价大跌。"}"#,
            diffSummary: "Replace example #2"
        )

        let projected = try AgentProposalArtifactsProjector.project(
            proposal: proposal,
            onto: baseline,
            mode: .preview
        )

        XCTAssertEqual(
            projected.acceptedExampleSentences,
            ["I ate an apple.", "Apple stock fell sharply after earnings."]
        )
        XCTAssertTrue(projected.suggestedExampleSentences.isEmpty)
    }

    func testPersistProjectionWritesSuggestedUsageCue() throws {
        let baseline = AIArtifacts(
            definitionNote: .init(
                accepted: DefinitionNoteArtifact(text: "Usually the fruit.")
            )
        )
        let proposal = ProposalRecord(
            kind: .usageCue,
            operation: .replace(targetID: "usage-cue"),
            payloadJSON: #"{"text":"Capital-A Apple is the company."}"#,
            diffSummary: "Replace usage cue"
        )

        let projected = try AgentProposalArtifactsProjector.project(
            proposal: proposal,
            onto: baseline,
            mode: .persist
        )

        XCTAssertEqual(projected.acceptedDefinitionNoteText, "Usually the fruit.")
        XCTAssertEqual(projected.suggestedDefinitionNoteText, "Capital-A Apple is the company.")
    }

    func testDeleteAcceptedProjectionRemovesAcceptedPitfall() throws {
        let baseline = AIArtifacts(
            pitfalls: .init(
                accepted: [
                    PitfallArtifact(id: "pf-1", text: "Company vs fruit"),
                    PitfallArtifact(id: "pf-2", text: "Avoid generic cues")
                ]
            )
        )
        let proposal = ProposalRecord(
            kind: .deleteAccepted,
            operation: .delete(targetID: "pf-1"),
            payloadJSON: #"{"section":"pitfall"}"#,
            diffSummary: "Delete accepted pitfall"
        )

        let projected = try AgentProposalArtifactsProjector.project(
            proposal: proposal,
            onto: baseline,
            mode: .persist
        )

        XCTAssertEqual(projected.acceptedPitfallTexts, ["Avoid generic cues"])
    }
}
