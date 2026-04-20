import AnkiMateRPC
import DictKitAnkiExport
import Foundation

public struct AgentToolRegistry {
    public let definitions: [LLMToolDefinition]

    private let snapshotLoader: @Sendable (UUID) throws -> CardRenderSnapshot

    public init(snapshotProvider: AgentCardSnapshotProviding) {
        self.init(snapshotLoader: { wordID in
            try snapshotProvider.snapshot(for: wordID)
        })
    }

    init(snapshotLoader: @escaping @Sendable (UUID) throws -> CardRenderSnapshot) {
        self.snapshotLoader = snapshotLoader
        self.definitions = [
            Self.toolDefinition(
                name: "read_card_snapshot",
                description: "Return the current rendered card snapshot, including wireframe and structured JSON."
            ),
            Self.toolDefinition(
                name: "list_accepted_artifacts",
                description: "Return the currently accepted card artifacts grouped by section."
            ),
            Self.proposalToolDefinition(
                name: "propose_usage_cue",
                description: "Create a pending usage-cue edit proposal."
            ),
            Self.proposalToolDefinition(
                name: "propose_example",
                description: "Create a pending example edit proposal."
            ),
            Self.proposalToolDefinition(
                name: "propose_recall_draft",
                description: "Create a pending recall-draft proposal."
            ),
            Self.proposalToolDefinition(
                name: "propose_pitfall",
                description: "Create a pending pitfall proposal."
            ),
            Self.proposalToolDefinition(
                name: "propose_mnemonic",
                description: "Create a pending mnemonic proposal."
            ),
            Self.proposalToolDefinition(
                name: "propose_collocation",
                description: "Create a pending collocation proposal."
            ),
            Self.proposalToolDefinition(
                name: "propose_delete_accepted",
                description: "Create a pending accepted-artifact deletion proposal."
            )
        ]
    }

    public func execute(_ toolCall: LLMToolCall, for wordID: UUID) throws -> MessageContent {
        switch toolCall.name {
        case "read_card_snapshot":
            return try executeReadCardSnapshot(for: wordID)
        case "list_accepted_artifacts":
            return try executeListAcceptedArtifacts(for: wordID)
        case "propose_usage_cue",
             "propose_example",
             "propose_recall_draft",
             "propose_pitfall",
             "propose_mnemonic",
             "propose_collocation",
             "propose_delete_accepted":
            return try executeProposal(toolCall)
        default:
            throw AgentToolRegistryError.unsupportedTool(toolCall.name)
        }
    }

    private func executeReadCardSnapshot(for wordID: UUID) throws -> MessageContent {
        let snapshot = try snapshotLoader(wordID)
        let payload = ReadCardSnapshotPayload(
            kind: snapshot.kind.rawValue,
            word: snapshot.word,
            phonetic: snapshot.phonetic,
            wireframe: snapshot.wireframe,
            structuredJSON: decodeJSONValue(from: snapshot.structuredJSON)
        )
        return .toolResult(
            name: "read_card_snapshot",
            resultJSON: try encode(payload),
            truncated: false
        )
    }

    private func executeListAcceptedArtifacts(for wordID: UUID) throws -> MessageContent {
        let snapshot = try snapshotLoader(wordID)
        let topLevel = decodeJSONObject(from: snapshot.structuredJSON)
        let artifacts = topLevel["artifacts"] ?? .object([:])
        let payload = AcceptedArtifactsPayload(
            word: snapshot.word,
            artifacts: artifacts
        )
        return .toolResult(
            name: "list_accepted_artifacts",
            resultJSON: try encode(payload),
            truncated: false
        )
    }

    private static func toolDefinition(name: String, description: String) -> LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private static func proposalToolDefinition(name: String, description: String) -> LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "operation": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("add"),
                            .string("replace"),
                            .string("delete")
                        ])
                    ]),
                    "targetID": .object([
                        "type": .string("string")
                    ]),
                    "diffSummary": .object([
                        "type": .string("string")
                    ]),
                    "rationale": .object([
                        "type": .string("string")
                    ]),
                    "payload": .object([
                        "type": .string("object")
                    ])
                ]),
                "required": .array([
                    .string("operation"),
                    .string("diffSummary"),
                    .string("payload")
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private func executeProposal(_ toolCall: LLMToolCall) throws -> MessageContent {
        guard case .object(let arguments) = toolCall.arguments else {
            throw AgentToolRegistryError.invalidArguments(toolCall.name)
        }
        let proposalKind = try proposalKind(for: toolCall.name)
        let operation = try proposalOperation(from: arguments)
        let diffSummary = try requiredString("diffSummary", in: arguments, toolName: toolCall.name)
        let rationale = optionalString("rationale", in: arguments)
        let payload = try requiredObject("payload", in: arguments, toolName: toolCall.name)

        let proposal = ProposalRecord(
            kind: proposalKind,
            operation: operation,
            payloadJSON: try encode(payload),
            diffSummary: diffSummary,
            rationale: rationale
        )
        return .actionProposal(proposal)
    }

    private func decodeJSONObject(from json: String) -> [String: JSONValue] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else {
            return [:]
        }
        return object
    }

    private func decodeJSONValue(from json: String) -> JSONValue {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(json)
        }
        return value
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentToolRegistryError.invalidPayload
        }
        return string
    }

    private func proposalKind(for toolName: String) throws -> ProposalRecord.ProposalKind {
        switch toolName {
        case "propose_usage_cue":
            return .usageCue
        case "propose_example":
            return .example
        case "propose_recall_draft":
            return .recallDraft
        case "propose_pitfall":
            return .pitfall
        case "propose_mnemonic":
            return .mnemonic
        case "propose_collocation":
            return .collocation
        case "propose_delete_accepted":
            return .deleteAccepted
        default:
            throw AgentToolRegistryError.unsupportedTool(toolName)
        }
    }

    private func proposalOperation(
        from arguments: [String: JSONValue]
    ) throws -> ProposalRecord.Operation {
        let rawOperation = try requiredString("operation", in: arguments, toolName: "proposal")
        switch rawOperation {
        case "add":
            return .add
        case "replace":
            let targetID = try requiredString("targetID", in: arguments, toolName: "proposal")
            return .replace(targetID: targetID)
        case "delete":
            let targetID = try requiredString("targetID", in: arguments, toolName: "proposal")
            return .delete(targetID: targetID)
        default:
            throw AgentToolRegistryError.invalidArguments("proposal")
        }
    }

    private func requiredString(
        _ key: String,
        in arguments: [String: JSONValue],
        toolName: String
    ) throws -> String {
        guard case .string(let value)? = arguments[key], !value.isEmpty else {
            throw AgentToolRegistryError.invalidArguments(toolName)
        }
        return value
    }

    private func optionalString(
        _ key: String,
        in arguments: [String: JSONValue]
    ) -> String? {
        guard case .string(let value)? = arguments[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private func requiredObject(
        _ key: String,
        in arguments: [String: JSONValue],
        toolName: String
    ) throws -> JSONValue {
        guard case .object? = arguments[key] else {
            throw AgentToolRegistryError.invalidArguments(toolName)
        }
        return arguments[key] ?? .object([:])
    }
}

public enum AgentToolRegistryError: LocalizedError {
    case unsupportedTool(String)
    case invalidPayload
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTool(let name):
            return "Unsupported agent tool: \(name)"
        case .invalidPayload:
            return "Failed to encode agent tool payload."
        case .invalidArguments(let name):
            return "Invalid arguments for agent tool: \(name)"
        }
    }
}

private struct ReadCardSnapshotPayload: Encodable {
    let kind: String
    let word: String
    let phonetic: String
    let wireframe: String
    let structuredJSON: JSONValue
}

private struct AcceptedArtifactsPayload: Encodable {
    let word: String
    let artifacts: JSONValue
}
