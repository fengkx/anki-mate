import AnkiMateRPC
import DictKitAnkiExport
import Foundation

public struct AgentToolRegistry {
    public let definitions: [LLMToolDefinition]

    private let snapshotLoader: @Sendable (UUID) throws -> CardRenderSnapshot
    private let artifactsLoader: ((UUID) throws -> AIArtifacts)?

    public init(
        snapshotProvider: AgentCardSnapshotProviding,
        artifactsProvider: AgentArtifactsManaging? = nil
    ) {
        self.init(snapshotLoader: { wordID in
            try snapshotProvider.snapshot(for: wordID)
        }, artifactsLoader: artifactsProvider.map { provider in
            { wordID in
                try provider.loadArtifacts(for: wordID)
            }
        })
    }

    init(
        snapshotLoader: @escaping @Sendable (UUID) throws -> CardRenderSnapshot,
        artifactsLoader: ((UUID) throws -> AIArtifacts)? = nil
    ) {
        self.snapshotLoader = snapshotLoader
        self.artifactsLoader = artifactsLoader
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
                description: "Create a pending usage-cue edit proposal.",
                payloadSchema: Self.definitionNotePayloadSchema()
            ),
            Self.proposalToolDefinition(
                name: "propose_example",
                description: """
                Create a pending example edit proposal. Use add when the user asks to add an example, even if the new sentence is based on a dictionary example or prior chat. Use replace/delete only for accepted example artifacts; dictionary sense examples are source material, not replace targets.
                """,
                payloadSchema: Self.examplePayloadSchema(),
                targetIDDescription: "targetID is required for replace/delete and must be an accepted example id such as ex-1. Never use sense ids like sense-0-0, dictionary sense ids, the headword, or section names. anchor.exampleIndex is only citation metadata inside payload, not a replace/delete target."
            ),
            Self.proposalToolDefinition(
                name: "propose_recall_draft",
                description: "Create a pending recall-draft proposal.",
                payloadSchema: Self.recallDraftPayloadSchema()
            ),
            Self.proposalToolDefinition(
                name: "propose_pitfall",
                description: "Create a pending pitfall proposal.",
                payloadSchema: Self.pitfallPayloadSchema()
            ),
            Self.proposalToolDefinition(
                name: "propose_mnemonic",
                description: """
                Create a pending mnemonic proposal. Use add to create a new mnemonic. Use replace/delete only for a specific accepted mnemonic referenced by targetID. Delete only the specific accepted mnemonic referenced by targetID and keep the other accepted mnemonics untouched.
                """,
                payloadSchema: Self.mnemonicPayloadSchema()
            ),
            Self.proposalToolDefinition(
                name: "propose_collocation",
                description: "Create a pending collocation proposal.",
                payloadSchema: Self.collocationPayloadSchema()
            )
        ]
    }

    public func execute(_ toolCall: LLMToolCall, for wordID: UUID) throws -> MessageContent {
        let toolCall = try normalizedToolCall(toolCall, for: wordID)
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
             "propose_collocation":
            return try executeProposal(toolCall)
        default:
            throw AgentToolRegistryError.unsupportedTool(toolCall.name)
        }
    }

    func normalizedToolCall(_ toolCall: LLMToolCall, for wordID: UUID) throws -> LLMToolCall {
        _ = wordID
        guard isProposalTool(toolCall.name) else {
            return toolCall
        }
        guard case .object(var arguments) = toolCall.arguments else {
            throw AgentToolRegistryError.invalidArguments(toolCall.name)
        }

        let proposalKind = try proposalKind(for: toolCall.name)
        let rawOperation = try requiredString("operation", in: arguments, toolName: toolCall.name)
        switch rawOperation {
        case "add":
            arguments.removeValue(forKey: "targetID")
        case "replace", "delete":
            let targetID = try requiredString("targetID", in: arguments, toolName: toolCall.name)
            guard isValidTargetID(targetID, for: proposalKind) else {
                throw AgentToolRegistryError.invalidArguments(toolCall.name)
            }
        default:
            throw AgentToolRegistryError.invalidArguments(toolCall.name)
        }

        return LLMToolCall(
            id: toolCall.id,
            name: toolCall.name,
            arguments: .object(arguments)
        )
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

    private static func proposalToolDefinition(
        name: String,
        description: String,
        payloadSchema: JSONValue,
        operationDescription: String = "Use add for new content, replace for editing an existing artifact, delete for removing an existing artifact.",
        targetIDDescription: String = "targetID is required for replace/delete. It must be a real existing artifact id from the current card snapshot or accepted artifacts; never use the headword or section name. When deleting only some existing items while keeping others, use the targetID for each specific artifact you want to delete."
    ) -> LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "operation": .object([
                        "type": .string("string"),
                        "description": .string(operationDescription),
                        "enum": .array([
                            .string("add"),
                            .string("replace"),
                            .string("delete")
                        ])
                    ]),
                    "targetID": .object([
                        "type": .string("string"),
                        "description": .string(targetIDDescription)
                    ]),
                    "diffSummary": .object([
                        "type": .string("string")
                    ]),
                    "rationale": .object([
                        "type": .string("string")
                    ]),
                    "payload": describedSchema(
                        payloadSchema,
                        description: "Required for add/replace. Omit it for delete; delete only needs operation and targetID."
                    )
                ]),
                "required": .array([
                    .string("operation")
                ]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private static func stringSchema() -> JSONValue {
        .object([
            "type": .string("string")
        ])
    }

    private static func boolSchema() -> JSONValue {
        .object([
            "type": .string("boolean")
        ])
    }

    private static func numberSchema() -> JSONValue {
        .object([
            "type": .string("number")
        ])
    }

    private static func enumStringSchema(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string))
        ])
    }

    private static func describedSchema(_ schema: JSONValue, description: String) -> JSONValue {
        guard case .object(var object) = schema else {
            return schema
        }
        object["description"] = .string(description)
        return .object(object)
    }

    private static func objectSchema(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static func anchorSchema() -> JSONValue {
        objectSchema(properties: [
            "headword": stringSchema(),
            "lexicalEntryIndex": numberSchema(),
            "senseIndex": numberSchema(),
            "exampleIndex": numberSchema(),
            "excerpt": stringSchema()
        ])
    }

    private static func senseReferenceSchema() -> JSONValue {
        objectSchema(properties: [
            "senseIndex": numberSchema(),
            "partOfSpeech": stringSchema(),
            "definitionSnapshot": stringSchema()
        ])
    }

    private static func definitionNotePayloadSchema() -> JSONValue {
        objectSchema(
            properties: [
                "text": stringSchema(),
                "anchor": anchorSchema()
            ],
            required: ["text"]
        )
    }

    private static func examplePayloadSchema() -> JSONValue {
        objectSchema(
            properties: [
                "text": stringSchema(),
                "translation": stringSchema(),
                "note": stringSchema(),
                "anchor": anchorSchema()
            ],
            required: ["text"]
        )
    }

    private static func recallDraftPayloadSchema() -> JSONValue {
        objectSchema(
            properties: [
                "mode": enumStringSchema(RecallCardMode.allCases.map(\.rawValue)),
                "front": stringSchema(),
                "back": stringSchema(),
                "hint": stringSchema(),
                "anchor": anchorSchema()
            ],
            required: ["mode", "front", "back"]
        )
    }

    private static func pitfallPayloadSchema() -> JSONValue {
        objectSchema(
            properties: [
                "text": stringSchema(),
                "translation": stringSchema(),
                "category": stringSchema(),
                "focus": stringSchema(),
                "recallRelevant": boolSchema(),
                "senseRef": senseReferenceSchema(),
                "anchor": anchorSchema()
            ],
            required: ["text"]
        )
    }

    private static func mnemonicPayloadSchema() -> JSONValue {
        objectSchema(
            properties: [
                "text": stringSchema(),
                "translation": stringSchema(),
                "kind": stringSchema(),
                "focus": stringSchema(),
                "recallRelevant": boolSchema(),
                "senseRef": senseReferenceSchema(),
                "anchor": anchorSchema()
            ],
            required: ["text"]
        )
    }

    private static func collocationPayloadSchema() -> JSONValue {
        objectSchema(
            properties: [
                "phrase": stringSchema(),
                "note": stringSchema(),
                "focus": stringSchema(),
                "recallRelevant": boolSchema(),
                "senseRef": senseReferenceSchema(),
                "anchor": anchorSchema()
            ],
            required: ["phrase"]
        )
    }

    private func executeProposal(_ toolCall: LLMToolCall) throws -> MessageContent {
        guard case .object(let arguments) = toolCall.arguments else {
            throw AgentToolRegistryError.invalidArguments(toolCall.name)
        }
        let proposalKind = try proposalKind(for: toolCall.name)
        let operation = try proposalOperation(from: arguments)
        let rationale = optionalString("rationale", in: arguments)
        let payload = try proposalPayload(
            from: arguments,
            operation: operation,
            toolName: toolCall.name
        )
        let payloadJSON = try encode(payload)
        let diffSummary = proposalDiffSummary(
            from: arguments,
            kind: proposalKind,
            operation: operation,
            payload: payload
        )

        try validateProposalPayload(
            kind: proposalKind,
            operation: operation,
            payloadJSON: payloadJSON,
            toolName: toolCall.name
        )

        let proposal = ProposalRecord(
            kind: proposalKind,
            operation: operation,
            payloadJSON: payloadJSON,
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
        default:
            throw AgentToolRegistryError.unsupportedTool(toolName)
        }
    }

    private func isProposalTool(_ toolName: String) -> Bool {
        switch toolName {
        case "propose_usage_cue",
             "propose_example",
             "propose_recall_draft",
             "propose_pitfall",
             "propose_mnemonic",
             "propose_collocation":
            return true
        default:
            return false
        }
    }

    private func isValidTargetID(
        _ targetID: String,
        for kind: ProposalRecord.ProposalKind
    ) -> Bool {
        let trimmed = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == targetID, !trimmed.isEmpty else {
            return false
        }

        switch kind {
        case .usageCue:
            return trimmed == "usage-cue"
        case .example:
            return isSyntheticID(trimmed, prefix: "ex-")
        case .recallDraft:
            return trimmed == "recall-draft"
        case .pitfall:
            return hasArtifactIDShape(trimmed, prefixes: ["pf-", "pitfall-"])
        case .mnemonic:
            return hasArtifactIDShape(trimmed, prefixes: ["mn-", "mnemonic-"])
        case .collocation:
            return hasArtifactIDShape(trimmed, prefixes: ["co-", "collocation-"])
        case .deleteAccepted:
            return trimmed == "usage-cue" ||
                trimmed == "recall-draft" ||
                isSyntheticID(trimmed, prefix: "ex-") ||
                hasArtifactIDShape(trimmed, prefixes: ["pf-", "pitfall-"]) ||
                hasArtifactIDShape(trimmed, prefixes: ["mn-", "mnemonic-"]) ||
                hasArtifactIDShape(trimmed, prefixes: ["co-", "collocation-"])
        }
    }

    private func isSyntheticID(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private func hasArtifactIDShape(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-"
        }
    }

    private func hasArtifactIDShape(_ value: String, prefixes: [String]) -> Bool {
        prefixes.contains { prefix in
            hasArtifactIDShape(value, prefix: prefix)
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

    private func proposalPayload(
        from arguments: [String: JSONValue],
        operation: ProposalRecord.Operation,
        toolName: String
    ) throws -> JSONValue {
        switch operation {
        case .delete:
            guard case .object? = arguments["payload"] else {
                return .object([:])
            }
            return arguments["payload"] ?? .object([:])
        case .add, .replace:
            return try requiredObject("payload", in: arguments, toolName: toolName)
        }
    }

    private func validateProposalPayload(
        kind: ProposalRecord.ProposalKind,
        operation: ProposalRecord.Operation,
        payloadJSON: String,
        toolName: String
    ) throws {
        if case .delete = operation, kind != .deleteAccepted {
            return
        }

        switch kind {
        case .usageCue:
            try decodePayload(DefinitionNoteArtifact.self, from: payloadJSON, toolName: toolName)
        case .example:
            try decodePayload(ExampleSentenceArtifact.self, from: payloadJSON, toolName: toolName)
        case .recallDraft:
            try decodePayload(RecallCardDraft.self, from: payloadJSON, toolName: toolName)
        case .pitfall:
            try decodePayload(PitfallArtifact.self, from: payloadJSON, toolName: toolName)
        case .mnemonic:
            try decodePayload(MnemonicArtifact.self, from: payloadJSON, toolName: toolName)
        case .collocation:
            try decodePayload(CollocationArtifact.self, from: payloadJSON, toolName: toolName)
        case .deleteAccepted:
            return
        }
    }

    private func decodePayload<T: Decodable>(
        _ type: T.Type,
        from payloadJSON: String,
        toolName: String
    ) throws {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw AgentToolRegistryError.invalidArguments(toolName)
        }

        do {
            _ = try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AgentToolRegistryError.invalidArguments(toolName)
        }
    }

    private func proposalDiffSummary(
        from arguments: [String: JSONValue],
        kind: ProposalRecord.ProposalKind,
        operation: ProposalRecord.Operation,
        payload: JSONValue
    ) -> String {
        if let explicit = optionalString("diffSummary", in: arguments) {
            return explicit
        }
        if let payloadSummary = payloadSummary(kind: kind, payload: payload) {
            return "\(operationLabel(operation)) \(kindLabel(kind)): \(payloadSummary)"
        }
        if let rationale = optionalString("rationale", in: arguments) {
            return rationale
        }
        return "\(operationLabel(operation)) \(kindLabel(kind))"
    }

    private func payloadSummary(kind: ProposalRecord.ProposalKind, payload: JSONValue) -> String? {
        guard case .object(let object) = payload else { return nil }
        let preferredKeys: [String]
        switch kind {
        case .usageCue, .example, .pitfall, .mnemonic:
            preferredKeys = ["text", "note"]
        case .recallDraft:
            preferredKeys = ["front", "mode", "hint"]
        case .collocation:
            preferredKeys = ["phrase", "note"]
        case .deleteAccepted:
            preferredKeys = ["section"]
        }
        return preferredKeys.lazy.compactMap { key in
            guard case .string(let value)? = object[key] else { return nil }
            return truncatedSummaryText(value)
        }.first
    }

    private func truncatedSummaryText(_ value: String, maxCharacters: Int = 140) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCharacters else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
        return String(trimmed[..<end]) + "..."
    }

    private func operationLabel(_ operation: ProposalRecord.Operation) -> String {
        switch operation {
        case .add:
            return "Add"
        case .replace:
            return "Replace"
        case .delete:
            return "Delete"
        }
    }

    private func kindLabel(_ kind: ProposalRecord.ProposalKind) -> String {
        switch kind {
        case .usageCue:
            return "usage cue"
        case .example:
            return "example"
        case .recallDraft:
            return "recall draft"
        case .pitfall:
            return "pitfall"
        case .mnemonic:
            return "mnemonic"
        case .collocation:
            return "collocation"
        case .deleteAccepted:
            return "accepted artifact"
        }
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
