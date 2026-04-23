import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import AnkiMateRPC
@testable import DictKitAnkiExport

final class AgentToolRegistryTests: XCTestCase {
    func testDefinitionsExposeReadOnlyTools() {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        XCTAssertEqual(registry.definitions.map(\.name), [
            "read_card_snapshot",
            "list_accepted_artifacts",
            "read_recall_card",
            "propose_usage_cue",
            "propose_example",
            "propose_recall_draft",
            "propose_pitfall",
            "propose_mnemonic",
            "propose_collocation",
            "propose_delete_accepted"
        ])
    }

    func testExecuteReadCardSnapshotReturnsSnapshotPayload() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        let content = try registry.execute(
            LLMToolCall(id: "call-1", name: "read_card_snapshot", arguments: .object([:])),
            for: UUID()
        )

        guard case .toolResult(let name, let resultJSON, let truncated) = content else {
            return XCTFail("Expected tool result")
        }
        XCTAssertEqual(name, "read_card_snapshot")
        XCTAssertFalse(truncated)
        XCTAssertTrue(resultJSON.contains(#""kind":"standard""#))
        XCTAssertTrue(resultJSON.contains(#""word":"apple""#))
        XCTAssertTrue(resultJSON.contains(#""structuredJSON":{"word":"apple"}"#))
    }

    func testExecuteListAcceptedArtifactsExtractsArtifactsObject() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.acceptedArtifactsSnapshot() })

        let content = try registry.execute(
            LLMToolCall(id: "call-2", name: "list_accepted_artifacts", arguments: .object([:])),
            for: UUID()
        )

        guard case .toolResult(_, let resultJSON, _) = content else {
            return XCTFail("Expected tool result")
        }
        XCTAssertTrue(resultJSON.contains(#""examples":[{"id":"ex-1","text":"Apple Inc. released a new model."}]"#))
        XCTAssertTrue(resultJSON.contains(#""usageCue":{"text":"Capital-A Apple is the company."}"#))
    }

    func testExecuteReadRecallCardReturnsAcceptedAndSuggestedDraftsFromArtifacts() throws {
        let accepted = RecallCardDraft(
            mode: .fullSpelling,
            front: "根据中文提示回忆完整拼写：苹果",
            back: "apple",
            hint: "fruit"
        )
        let suggested = RecallCardDraft(
            mode: .targetedLetterCloze,
            front: "a____",
            back: "apple",
            hint: nil
        )
        let registry = AgentToolRegistry(
            snapshotLoader: { _ in Self.sampleSnapshot() },
            artifactsLoader: { _ in
                AIArtifacts(
                    recallCardDrafts: .init(
                        suggested: [suggested],
                        accepted: [accepted]
                    )
                )
            }
        )

        let content = try registry.execute(
            LLMToolCall(id: "call-recall", name: "read_recall_card", arguments: .object([:])),
            for: UUID()
        )

        guard case .toolResult(let name, let resultJSON, let truncated) = content else {
            return XCTFail("Expected tool result")
        }
        XCTAssertEqual(name, "read_recall_card")
        XCTAssertFalse(truncated)
        XCTAssertTrue(resultJSON.contains(#""word":"apple""#))
        XCTAssertTrue(resultJSON.contains(#""hasAccepted":true"#))
        XCTAssertTrue(resultJSON.contains(#""accepted":[{"back":"apple","front":"根据中文提示回忆完整拼写：苹果","hint":"fruit","mode":"full_spelling"}]"#))
        XCTAssertTrue(resultJSON.contains(#""suggested":[{"back":"apple","front":"a____","mode":"targeted_letter_cloze"}]"#))
    }

    func testExecuteReadRecallCardRejectsLegacyMisspelling() {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        XCTAssertThrowsError(
            try registry.execute(
                LLMToolCall(id: "call-recall", name: "read_reacall_card", arguments: .object([:])),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported agent tool: read_reacall_card"
            )
        }
    }

    func testExecuteProposeExampleBuildsPendingProposal() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        let content = try registry.execute(
            LLMToolCall(
                id: "call-3",
                name: "propose_example",
                arguments: .object([
                    "operation": .string("replace"),
                    "targetID": .string("ex-2"),
                    "diffSummary": .string("Replace example #2 with a business example"),
                    "rationale": .string("Current example is too generic"),
                    "payload": .object([
                        "text": .string("Apple stock fell sharply after earnings."),
                        "translation": .string("苹果公司财报后股价大跌。")
                    ])
                ])
            ),
            for: UUID()
        )

        guard case .actionProposal(let proposal) = content else {
            return XCTFail("Expected proposal content")
        }
        XCTAssertEqual(proposal.kind, .example)
        XCTAssertEqual(proposal.operation, .replace(targetID: "ex-2"))
        XCTAssertEqual(proposal.decision, .pending)
        XCTAssertEqual(proposal.diffSummary, "Replace example #2 with a business example")
        XCTAssertEqual(proposal.rationale, "Current example is too generic")
        XCTAssertTrue(proposal.payloadJSON.contains(#""text":"Apple stock fell sharply after earnings.""#))
    }

    func testExecuteProposeExampleDerivesSummaryWhenModelOmitsDiffSummary() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        let content = try registry.execute(
            LLMToolCall(
                id: "call-lemmatize-example",
                name: "propose_example",
                arguments: .object([
                    "operation": .string("add"),
                    "rationale": .string("为学习者提供一个关于词形还原在技术或学习场景中应用的例句，帮助理解该词的实际应用。"),
                    "payload": .object([
                        "note": .string("这个例句侧重于说明使用 lemmatize 的目的：将一个词还原到其基本形式，这在词汇分析和学习中非常常见。"),
                        "text": .string("The software automatically lemmatizes complex words to help users understand the root form."),
                        "translation": .string("该软件会自动对复杂的词语进行词形还原，以帮助用户理解其词根形式。")
                    ])
                ])
            ),
            for: UUID()
        )

        guard case .actionProposal(let proposal) = content else {
            return XCTFail("Expected proposal content")
        }
        XCTAssertEqual(proposal.kind, .example)
        XCTAssertEqual(proposal.operation, .add)
        XCTAssertEqual(
            proposal.diffSummary,
            "Add example: The software automatically lemmatizes complex words to help users understand the root form."
        )
        XCTAssertEqual(
            proposal.rationale,
            "为学习者提供一个关于词形还原在技术或学习场景中应用的例句，帮助理解该词的实际应用。"
        )
        XCTAssertTrue(proposal.payloadJSON.contains(#""note":"这个例句侧重于说明使用 lemmatize 的目的"#))
    }

    func testNormalizeProposalAddRemovesTargetID() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        let normalized = try registry.normalizedToolCall(
            LLMToolCall(
                id: "call-add",
                name: "propose_example",
                arguments: .object([
                    "operation": .string("add"),
                    "targetID": .string("corpus"),
                    "diffSummary": .string("Add an academic example"),
                    "payload": .object([
                        "text": .string("The corpus reveals regional usage patterns.")
                    ])
                ])
            ),
            for: UUID()
        )

        guard case .object(let arguments) = normalized.arguments else {
            return XCTFail("Expected normalized arguments object")
        }
        XCTAssertNil(arguments["targetID"])

        let content = try registry.execute(normalized, for: UUID())
        guard case .actionProposal(let proposal) = content else {
            return XCTFail("Expected proposal content")
        }
        XCTAssertEqual(proposal.operation, ProposalRecord.Operation.add)
    }

    func testNormalizeProposalReplaceRejectsMissingOrInvalidTargetID() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        XCTAssertThrowsError(
            try registry.normalizedToolCall(
                LLMToolCall(
                    id: "call-replace-missing",
                    name: "propose_example",
                    arguments: .object([
                        "operation": .string("replace"),
                        "diffSummary": .string("Replace an example"),
                        "payload": .object([
                            "text": .string("The corpus reveals regional usage patterns.")
                        ])
                    ])
                ),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid arguments for agent tool: propose_example")
        }

        XCTAssertThrowsError(
            try registry.normalizedToolCall(
                LLMToolCall(
                    id: "call-replace-invalid",
                    name: "propose_example",
                    arguments: .object([
                        "operation": .string("replace"),
                        "targetID": .string("corpus"),
                        "diffSummary": .string("Replace an example"),
                        "payload": .object([
                            "text": .string("The corpus reveals regional usage patterns.")
                        ])
                    ])
                ),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid arguments for agent tool: propose_example")
        }
    }

    func testExecuteProposePitfallRejectsMissingRequiredText() {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        XCTAssertThrowsError(
            try registry.execute(
                LLMToolCall(
                    id: "call-4",
                    name: "propose_pitfall",
                    arguments: .object([
                        "operation": .string("add"),
                        "diffSummary": .string("Add a pitfall"),
                        "payload": .object([:])
                    ])
                ),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid arguments for agent tool: propose_pitfall"
            )
        }
    }

    private static func sampleSnapshot() -> CardRenderSnapshot {
        CardRenderSnapshot(
            kind: .standard,
            word: "apple",
            phonetic: "/ˈæp.əl/",
            wireframe: "wireframe",
            structuredJSON: #"{"word":"apple"}"#,
            aiSectionOrder: []
        )
    }

    private static func acceptedArtifactsSnapshot() -> CardRenderSnapshot {
        CardRenderSnapshot(
            kind: .standard,
            word: "apple",
            phonetic: "/ˈæp.əl/",
            wireframe: "wireframe",
            structuredJSON: #"{"artifacts":{"examples":[{"id":"ex-1","text":"Apple Inc. released a new model."}],"usageCue":{"text":"Capital-A Apple is the company."}},"word":"apple"}"#,
            aiSectionOrder: [.usageCue, .examples]
        )
    }
}
