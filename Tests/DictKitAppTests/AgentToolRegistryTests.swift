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
            "propose_usage_cue",
            "propose_example",
            "propose_recall_draft",
            "propose_pitfall",
            "propose_mnemonic",
            "propose_collocation"
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

    func testReadRecallCardToolIsNotExposed() {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        XCTAssertThrowsError(
            try registry.execute(
                LLMToolCall(id: "call-recall", name: "read_recall_card", arguments: .object([:])),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported agent tool: read_recall_card"
            )
        }
    }

    func testDeleteAcceptedToolIsNotExposedOrExecutable() {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        XCTAssertNil(registry.definitions.first(where: { $0.name == "propose_delete_accepted" }))
        XCTAssertThrowsError(
            try registry.execute(
                LLMToolCall(
                    id: "call-delete-accepted",
                    name: "propose_delete_accepted",
                    arguments: .object([
                        "operation": .string("delete"),
                        "targetID": .string("mnemonic-0-perpetual-repeat"),
                        "payload": .object([
                            "section": .string("mnemonic")
                        ])
                    ])
                ),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Unsupported agent tool: propose_delete_accepted"
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

        XCTAssertThrowsError(
            try registry.normalizedToolCall(
                LLMToolCall(
                    id: "call-replace-sense-id",
                    name: "propose_example",
                    arguments: .object([
                        "operation": .string("replace"),
                        "targetID": .string("sense-0-0"),
                        "diffSummary": .string("Replace dictionary example"),
                        "payload": .object([
                            "text": .string("The model was ravenous for tokens.")
                        ])
                    ])
                ),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid arguments for agent tool: propose_example")
        }
    }

    func testNormalizeProposalReplaceAcceptsRenderedMnemonicArtifactID() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.acceptedArtifactsSnapshot() })

        let normalized = try registry.normalizedToolCall(
            LLMToolCall(
                id: "call-replace-mnemonic",
                name: "propose_mnemonic",
                arguments: .object([
                    "operation": .string("replace"),
                    "targetID": .string("mnemonic-0-perpetual-repeat"),
                    "diffSummary": .string("Replace translation mnemonic with a word-structure mnemonic"),
                    "payload": .object([
                        "text": .string("perpetual starts with per-, so anchor the first blank to per rather than pa.")
                    ])
                ])
            ),
            for: UUID()
        )

        let content = try registry.execute(normalized, for: UUID())
        guard case .actionProposal(let proposal) = content else {
            return XCTFail("Expected proposal content")
        }
        XCTAssertEqual(proposal.kind, .mnemonic)
        XCTAssertEqual(proposal.operation, .replace(targetID: "mnemonic-0-perpetual-repeat"))
    }

    func testExecuteProposeMnemonicDeleteDoesNotRequirePayload() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.acceptedArtifactsSnapshot() })

        let content = try registry.execute(
            LLMToolCall(
                id: "call-delete-mnemonic",
                name: "propose_mnemonic",
                arguments: .object([
                    "operation": .string("delete"),
                    "targetID": .string("mnemonic-0-perpetual-repeat"),
                    "diffSummary": .string("Delete translation mnemonic")
                ])
            ),
            for: UUID()
        )

        guard case .actionProposal(let proposal) = content else {
            return XCTFail("Expected proposal content")
        }
        XCTAssertEqual(proposal.kind, .mnemonic)
        XCTAssertEqual(proposal.operation, .delete(targetID: "mnemonic-0-perpetual-repeat"))
        XCTAssertEqual(proposal.payloadJSON, "{}")
    }

    func testProposalToolDefinitionsExplainSelectiveDeleteContracts() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        let mnemonic = try XCTUnwrap(registry.definitions.first(where: { $0.name == "propose_mnemonic" }))
        let mnemonicDescription = try XCTUnwrap(mnemonic.description)

        XCTAssertTrue(mnemonicDescription.contains("Delete only the specific accepted mnemonic referenced by targetID"))
        XCTAssertTrue(mnemonicDescription.contains("keep the other accepted mnemonics untouched"))
        XCTAssertNil(registry.definitions.first(where: { $0.name == "propose_delete_accepted" }))
    }

    func testProposalToolSchemasDescribeTargetIDForSelectiveDeletes() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        let mnemonic = try XCTUnwrap(registry.definitions.first(where: { $0.name == "propose_mnemonic" }))
        let mnemonicParameters = try XCTUnwrap(mnemonic.parameters)

        let mnemonicTargetDescription = try XCTUnwrap(
            Self.stringPropertyDescription(
                named: "targetID",
                in: mnemonicParameters
            )
        )
        let required = Self.requiredProperties(in: mnemonicParameters)
        XCTAssertTrue(mnemonicTargetDescription.contains("required for replace/delete"))
        XCTAssertTrue(mnemonicTargetDescription.contains("real existing artifact id from the current card snapshot or accepted artifacts"))
        XCTAssertTrue(mnemonicTargetDescription.contains("When deleting only some existing items while keeping others"))
        XCTAssertEqual(
            Self.objectPropertyDescription(named: "payload", in: mnemonicParameters),
            "Required for add/replace. Omit it for delete; delete only needs operation and targetID."
        )
        XCTAssertEqual(required, ["operation"])
    }

    func testExampleToolDefinitionDistinguishesAcceptedExamplesFromDictionaryExamples() throws {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        let example = try XCTUnwrap(registry.definitions.first(where: { $0.name == "propose_example" }))
        let description = try XCTUnwrap(example.description)
        let parameters = try XCTUnwrap(example.parameters)
        let targetDescription = try XCTUnwrap(
            Self.stringPropertyDescription(
                named: "targetID",
                in: parameters
            )
        )

        XCTAssertTrue(description.contains("Use add when the user asks to add an example"))
        XCTAssertTrue(description.contains("dictionary sense examples are source material, not replace targets"))
        XCTAssertTrue(targetDescription.contains("accepted example id such as ex-1"))
        XCTAssertTrue(targetDescription.contains("Never use sense ids like sense-0-0"))
        XCTAssertTrue(targetDescription.contains("anchor.exampleIndex is only citation metadata"))
    }

    func testExecuteProposeExampleAddRejectsMissingPayload() {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })

        XCTAssertThrowsError(
            try registry.execute(
                LLMToolCall(
                    id: "call-add-missing-payload",
                    name: "propose_example",
                    arguments: .object([
                        "operation": .string("add")
                    ])
                ),
                for: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Invalid arguments for agent tool: propose_example"
            )
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

    private static func stringPropertyDescription(
        named propertyName: String,
        in schema: AnkiMateRPC.JSONValue
    ) -> String? {
        guard case .object(let root) = schema,
              case .object(let properties)? = root["properties"],
              case .object(let property)? = properties[propertyName],
              case .string(let description)? = property["description"] else {
            return nil
        }
        return description
    }

    private static func objectPropertyDescription(
        named propertyName: String,
        in schema: AnkiMateRPC.JSONValue
    ) -> String? {
        guard case .object(let root) = schema,
              case .object(let properties)? = root["properties"],
              case .object(let property)? = properties[propertyName],
              case .string(let description)? = property["description"] else {
            return nil
        }
        return description
    }

    private static func stringPropertyDescription(
        named propertyName: String,
        inPayloadOf schema: AnkiMateRPC.JSONValue
    ) -> String? {
        guard case .object(let root) = schema,
              case .object(let properties)? = root["properties"],
              case .object(let payload)? = properties["payload"],
              case .object(let payloadProperties)? = payload["properties"],
              case .object(let property)? = payloadProperties[propertyName],
              case .string(let description)? = property["description"] else {
            return nil
        }
        return description
    }

    private static func requiredProperties(in schema: AnkiMateRPC.JSONValue) -> [String] {
        guard case .object(let root) = schema,
              case .array(let values)? = root["required"] else {
            return []
        }
        return values.compactMap { value in
            guard case .string(let name) = value else { return nil }
            return name
        }
    }
}
