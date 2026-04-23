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
        XCTAssertEqual(
            projected.exampleSentences.accepted?[1].translation,
            "苹果公司财报后股价大跌。"
        )
        XCTAssertTrue(projected.suggestedExampleSentences.isEmpty)
    }

    func testExampleReplaceRejectsMissingTargetInsteadOfAppending() throws {
        let baseline = AIArtifacts(
            exampleSentences: .init(
                accepted: [
                    ExampleSentenceArtifact(text: "I ate an apple.")
                ]
            )
        )
        let proposal = ProposalRecord(
            kind: .example,
            operation: .replace(targetID: "corpus"),
            payloadJSON: #"{"text":"The corpus reveals regional usage patterns."}"#,
            diffSummary: "Replace example"
        )

        XCTAssertThrowsError(
            try AgentProposalArtifactsProjector.project(
                proposal: proposal,
                onto: baseline,
                mode: .preview
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Agent proposal target is unavailable."
            )
        }
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
