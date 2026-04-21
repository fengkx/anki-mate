import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import AnkiMateRPC
@testable import DictKitAnkiExport

@MainActor
final class AgentSessionTests: XCTestCase {
    func testReloadLoadsPersistedMessagesAndPendingProposals() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let sessionRecord = try persistence.upsertSession(for: wordID)
        let pending = ProposalRecord(
            kind: .example,
            operation: .add,
            payloadJSON: #"{"text":"Apple stock fell sharply.","translation":"苹果公司股价大跌。"}"#,
            diffSummary: "Add business example"
        )
        var applied = ProposalRecord(
            kind: .pitfall,
            operation: .add,
            payloadJSON: #"{"id":"pf-1","text":"Company vs fruit"}"#,
            diffSummary: "Add pitfall"
        )
        applied.decision = .applied

        _ = try persistence.addMessage(sessionID: sessionRecord.id, role: .assistant, content: .actionProposal(pending))
        _ = try persistence.addMessage(sessionID: sessionRecord.id, role: .assistant, content: .actionProposal(applied))

        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()

        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(sut.pendingProposals.map(\.diffSummary), ["Add business example"])
    }

    func testSendUserMessagePersistsUserAndAssistantMessagesAndCallsGenerator() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(text: "我会保留商业例句，只缩短第二句。", tokensUsed: 42, durationMs: 12)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("把第二个例句换短一点")

        XCTAssertEqual(sut.messages.count, 2)
        XCTAssertEqual(sut.messages[0].role, .user)
        XCTAssertEqual(sut.messages[1].role, .assistant)
        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertTrue(generator.calls[0].contains { $0.role == .system })
        XCTAssertTrue(generator.calls[0].contains { $0.content.contains("把第二个例句换短一点") })
        XCTAssertTrue(generator.calls[0].contains { $0.content.contains("Current card snapshot") })
    }

    func testSendUserMessageRollsBackMessagesAndRethrowsWhenGenerationFails() async throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(error: Failure.stub)
        )

        try sut.reload()

        do {
            try await sut.sendUserMessage("帮我缩短 back")
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is Failure)
        }

        // The user message should have been rolled back — no messages remain.
        XCTAssertEqual(sut.messages.count, 0)
    }

    func testSendUserMessageExecutesReadToolCallsBeforePersistingAssistantReply() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            results: [
                GenerateResult(
                    text: "",
                    tokensUsed: 12,
                    durationMs: 4,
                    toolCalls: [
                        LLMToolCall(id: "call-1", name: "read_card_snapshot", arguments: .object([:]))
                    ]
                ),
                GenerateResult(
                    text: "这张卡目前只有基础释义，我会先基于现有内容给建议。",
                    tokensUsed: 18,
                    durationMs: 6
                )
            ]
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("先看看这张卡现在长什么样")

        XCTAssertEqual(generator.calls.count, 2)
        XCTAssertEqual(sut.messages.count, 4)
        XCTAssertEqual(sut.messages[0].role, .user)
        XCTAssertEqual(sut.messages[1].role, .assistant)
        XCTAssertEqual(sut.messages[2].role, .tool)
        XCTAssertEqual(sut.messages[3].role, .assistant)

        guard case .toolCall(let name, _) = sut.messages[1].content else {
            return XCTFail("Expected persisted tool call")
        }
        XCTAssertEqual(name, "read_card_snapshot")

        guard case .toolResult(let resultName, let resultJSON, _) = sut.messages[2].content else {
            return XCTFail("Expected persisted tool result")
        }
        XCTAssertEqual(resultName, "read_card_snapshot")
        XCTAssertTrue(resultJSON.contains(#""word":"apple""#))
        XCTAssertTrue(resultJSON.contains(#""structuredJSON":{"word":"apple"}"#))

        XCTAssertTrue(generator.calls[1].contains { $0.role == .tool && $0.content.contains("read_card_snapshot") })
        XCTAssertTrue(generator.calls[1].contains { $0.content.contains(#""word":"apple""#) })
    }

    func testSendUserMessageShortCircuitsLayoutRequestsIntoDeclinedMessage() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(text: "unused", tokensUsed: 1, durationMs: 1)
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("把 pitfalls 挪到 examples 前面")

        XCTAssertEqual(generator.calls.count, 0)
        XCTAssertEqual(sut.messages.count, 2)
        guard case .layoutRequestDeclined(let userText, let detectedKind) = sut.messages[1].content else {
            return XCTFail("Expected layout_request_declined message")
        }
        XCTAssertEqual(userText, "把 pitfalls 挪到 examples 前面")
        XCTAssertEqual(detectedKind, .layout)
    }

    func testSendUserMessagePersistsAssistantTextAndPendingProposalForWriteToolCalls() async throws {
        let persistence = InMemoryAgentPersistence()
        let generator = RecordingGenerator(
            result: GenerateResult(
                text: "第二个例句太泛了，换成商业语境会更利于区分 fruit 和 company。",
                tokensUsed: 24,
                durationMs: 8,
                toolCalls: [
                    LLMToolCall(
                        id: "call-4",
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
                    )
                ]
            )
        )
        let wordID = UUID()
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: generator
        )

        try sut.reload()
        try await sut.sendUserMessage("把第二个例句换成商业语境")

        XCTAssertEqual(generator.calls.count, 1)
        XCTAssertEqual(sut.messages.count, 4)
        XCTAssertEqual(sut.pendingProposals.count, 1)

        guard case .text(let assistantText, reasoning: _) = sut.messages[1].content else {
            return XCTFail("Expected assistant rationale text")
        }
        XCTAssertTrue(assistantText.contains("商业语境"))

        guard case .toolCall(let toolName, _) = sut.messages[2].content else {
            return XCTFail("Expected tool call trace")
        }
        XCTAssertEqual(toolName, "propose_example")

        guard case .actionProposal(let proposal) = sut.messages[3].content else {
            return XCTFail("Expected proposal message")
        }
        XCTAssertEqual(proposal.kind, .example)
        XCTAssertEqual(proposal.operation, .replace(targetID: "ex-2"))
        XCTAssertEqual(proposal.decision, .pending)
    }

    func testClearChatKeepsSessionButRemovesMessages() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let sessionRecord = try persistence.upsertSession(for: wordID)
        _ = try persistence.addMessage(sessionID: sessionRecord.id, role: .user, content: .text("hello"))

        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )
        try sut.reload()

        try sut.clearChat()

        XCTAssertNotNil(sut.sessionRecord)
        XCTAssertTrue(sut.messages.isEmpty)
    }

    func testPreviewOverrideRoundTrips() throws {
        let sut = AgentSession(
            wordID: UUID(),
            persistence: InMemoryAgentPersistence(),
            snapshotProvider: StaticSnapshotProvider(),
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )
        let override = AIArtifacts(
            pitfalls: .init(
                suggested: [PitfallArtifact(id: "pf-1", text: "Company vs fruit")],
                accepted: nil
            )
        )

        sut.setPreviewOverrideArtifacts(override)
        XCTAssertEqual(sut.previewOverrideArtifacts, override)

        sut.clearPreviewOverride()
        XCTAssertNil(sut.previewOverrideArtifacts)
    }

    func testPreviewProposalProjectsArtifactsIntoOverrideState() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let proposal = ProposalRecord(
            kind: .example,
            operation: .replace(targetID: "ex-2"),
            payloadJSON: #"{"text":"Apple stock fell sharply after earnings.","translation":"苹果公司财报后股价大跌。"}"#,
            diffSummary: "Replace example #2 with a business example"
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .actionProposal(proposal))
        let artifactsManager = InMemoryArtifactsManager(
            artifactsByWordID: [
                wordID: AIArtifacts(
                    exampleSentences: .init(
                        accepted: [
                            ExampleSentenceArtifact(text: "I ate an apple."),
                            ExampleSentenceArtifact(text: "She packed an apple in his lunch.")
                        ]
                    )
                )
            ]
        )
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            artifactsManager: artifactsManager,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()
        try sut.previewProposal(proposal.id)

        XCTAssertEqual(
            sut.previewOverrideArtifacts?.acceptedExampleSentences,
            ["I ate an apple.", "Apple stock fell sharply after earnings."]
        )
    }

    func testApplyProposalPersistsArtifactsAndMarksProposalApplied() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let proposal = ProposalRecord(
            kind: .example,
            operation: .replace(targetID: "ex-2"),
            payloadJSON: #"{"text":"Apple stock fell sharply after earnings.","translation":"苹果公司财报后股价大跌。"}"#,
            diffSummary: "Replace example #2 with a business example"
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .actionProposal(proposal))
        let artifactsManager = InMemoryArtifactsManager(
            artifactsByWordID: [
                wordID: AIArtifacts(
                    exampleSentences: .init(
                        accepted: [
                            ExampleSentenceArtifact(text: "I ate an apple."),
                            ExampleSentenceArtifact(text: "She packed an apple in his lunch.")
                        ]
                    )
                )
            ]
        )
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            artifactsManager: artifactsManager,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()
        try sut.applyProposal(proposal.id)

        XCTAssertEqual(sut.pendingProposals.count, 0)
        XCTAssertNil(sut.previewOverrideArtifacts)
        XCTAssertEqual(
            try artifactsManager.loadArtifacts(for: wordID).suggestedExampleSentences,
            ["I ate an apple.", "Apple stock fell sharply after earnings."]
        )
        guard case .actionProposal(let applied) = sut.messages[0].content else {
            return XCTFail("Expected proposal message")
        }
        XCTAssertEqual(applied.decision, .applied)
        XCTAssertNotNil(applied.decidedAt)
    }

    func testDismissProposalMarksProposalDismissedWithoutMutatingArtifacts() throws {
        let persistence = InMemoryAgentPersistence()
        let wordID = UUID()
        let session = try persistence.upsertSession(for: wordID)
        let proposal = ProposalRecord(
            kind: .usageCue,
            operation: .replace(targetID: "usage-cue"),
            payloadJSON: #"{"text":"Capital-A Apple is the company."}"#,
            diffSummary: "Replace usage cue"
        )
        _ = try persistence.addMessage(sessionID: session.id, role: .assistant, content: .actionProposal(proposal))
        let artifactsManager = InMemoryArtifactsManager(
            artifactsByWordID: [
                wordID: AIArtifacts(
                    definitionNote: .init(accepted: DefinitionNoteArtifact(text: "Usually the fruit."))
                )
            ]
        )
        let sut = AgentSession(
            wordID: wordID,
            persistence: persistence,
            snapshotProvider: StaticSnapshotProvider(),
            artifactsManager: artifactsManager,
            generator: RecordingGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        try sut.reload()
        try sut.dismissProposal(proposal.id)

        XCTAssertEqual(sut.pendingProposals.count, 0)
        XCTAssertEqual(try artifactsManager.loadArtifacts(for: wordID).acceptedDefinitionNoteText, "Usually the fruit.")
        guard case .actionProposal(let dismissed) = sut.messages[0].content else {
            return XCTFail("Expected proposal message")
        }
        XCTAssertEqual(dismissed.decision, .dismissed)
        XCTAssertNotNil(dismissed.decidedAt)
    }
}

private struct StaticSnapshotProvider: AgentCardSnapshotProviding {
    func snapshot(for wordID: UUID) throws -> CardRenderSnapshot {
        CardRenderSnapshot(
            kind: .standard,
            word: "apple",
            phonetic: "/ˈæp.əl/",
            wireframe: """
            ┌─────────── FRONT ──────────────────────────────┐
            │ apple                                         │
            └───────────────────────────────────────────────┘
            """,
            structuredJSON: #"{"word":"apple"}"#,
            aiSectionOrder: []
        )
    }
}

private final class RecordingGenerator: AgentGenerating {
    let result: GenerateResult?
    let results: [GenerateResult]
    let error: Error?
    private(set) var calls: [[LLMMessage]] = []
    private var nextResultIndex = 0

    init(result: GenerateResult? = nil, results: [GenerateResult] = [], error: Error? = nil) {
        self.result = result
        self.results = results
        self.error = error
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult {
        calls.append(messages)
        if let error {
            throw error
        }
        if nextResultIndex < results.count {
            defer { nextResultIndex += 1 }
            return results[nextResultIndex]
        }
        return result ?? GenerateResult(text: "", tokensUsed: 0, durationMs: 0)
    }
}

private final class InMemoryAgentPersistence: AgentSessionPersisting {
    private(set) var sessionsByWordID: [UUID: AgentChatSession] = [:]
    private(set) var messagesBySessionID: [UUID: [AgentChatMessage]] = [:]

    func upsertSession(for wordID: UUID, preferences: AgentSessionPreferences) throws -> AgentChatSession {
        if var existing = sessionsByWordID[wordID] {
            existing.preferences = preferences
            existing.updatedAt = Date()
            sessionsByWordID[wordID] = existing
            return existing
        }

        let created = AgentChatSession(wordItemID: wordID, preferences: preferences)
        sessionsByWordID[wordID] = created
        return created
    }

    func session(for wordID: UUID) throws -> AgentChatSession? {
        sessionsByWordID[wordID]
    }

    func loadMessages(sessionID: UUID) throws -> [AgentChatMessage] {
        messagesBySessionID[sessionID] ?? []
    }

    func addMessage(
        sessionID: UUID,
        role: AgentChatMessage.Role,
        status: AgentChatMessage.Status,
        content: MessageContent,
        createdAt: Date,
        supersededBy: UUID?,
        interrupted: Bool
    ) throws -> AgentChatMessage {
        let ordinal = (messagesBySessionID[sessionID]?.last?.ordinal ?? 0) + 1
        let message = AgentChatMessage(
            sessionID: sessionID,
            ordinal: ordinal,
            role: role,
            createdAt: createdAt,
            status: status,
            content: content,
            supersededBy: supersededBy,
            interrupted: interrupted
        )
        messagesBySessionID[sessionID, default: []].append(message)
        return message
    }

    func deleteMessages(ids: [UUID]) throws {
        for (sessionID, messages) in messagesBySessionID {
            messagesBySessionID[sessionID] = messages.filter { !ids.contains($0.id) }
        }
    }

    func clearMessages(sessionID: UUID) throws {
        messagesBySessionID[sessionID] = []
    }

    func resetSession(for wordID: UUID) throws {
        guard let session = sessionsByWordID.removeValue(forKey: wordID) else { return }
        messagesBySessionID.removeValue(forKey: session.id)
    }

    func updateProposal(messageID: UUID, proposal: ProposalRecord) throws -> AgentChatMessage {
        for (sessionID, messages) in messagesBySessionID {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else { continue }
            let original = messages[index]
            let updated = AgentChatMessage(
                id: original.id,
                sessionID: original.sessionID,
                ordinal: original.ordinal,
                role: original.role,
                createdAt: original.createdAt,
                status: original.status,
                content: .actionProposal(proposal),
                supersededBy: original.supersededBy,
                interrupted: original.interrupted
            )
            messagesBySessionID[sessionID]?[index] = updated
            return updated
        }
        throw Failure.stub
    }
}

private final class InMemoryArtifactsManager: AgentArtifactsManaging {
    var artifactsByWordID: [UUID: AIArtifacts]

    init(artifactsByWordID: [UUID: AIArtifacts] = [:]) {
        self.artifactsByWordID = artifactsByWordID
    }

    func loadArtifacts(for wordID: UUID) throws -> AIArtifacts {
        artifactsByWordID[wordID] ?? .empty
    }

    func saveArtifacts(_ artifacts: AIArtifacts, for wordID: UUID) throws {
        artifactsByWordID[wordID] = artifacts
    }
}

private enum Failure: LocalizedError {
    case stub

    var errorDescription: String? {
        "stub failure"
    }
}
