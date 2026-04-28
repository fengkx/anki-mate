import XCTest
@testable import AnkiMateLLM
@testable import AnkiMateRPC
@testable import DictKitAnkiExport
@testable import DictKitApp

@MainActor
final class AIContentViewTests: XCTestCase {
    func testTrackedGenerationKeepsOwningWordMarkedLoadingUntilWorkFinishes() async {
        let item = WordItem(word: "apple")
        let gate = AsyncGate()

        let task = AITrackedGenerationRunner.start(item: item, action: .examples) {
            await gate.wait()
        }

        XCTAssertTrue(item.isGeneratingAI)
        XCTAssertTrue(item.isGeneratingAI(for: .examples))
        XCTAssertFalse(item.isGeneratingAI(for: .usage))

        await gate.open()
        await task.value

        XCTAssertFalse(item.isGeneratingAI)
        XCTAssertFalse(item.isGeneratingAI(for: .examples))
    }

    func testTrackedGenerationStoresErrorOnOwningWordAndClearsOnlyFailedAction() async {
        let item = WordItem(word: "apple")
        item.beginAIGeneration(.usage)

        let task = AITrackedGenerationRunner.start(item: item, action: .examples) {
            throw TestGenerationError.failed
        }

        await task.value

        XCTAssertTrue(item.isGeneratingAI)
        XCTAssertFalse(item.isGeneratingAI(for: .examples))
        XCTAssertTrue(item.isGeneratingAI(for: .usage))
        XCTAssertEqual(item.aiGenerationError(for: .examples), TestGenerationError.failed.localizedDescription)
        XCTAssertNil(item.aiGenerationError(for: .usage))
    }

    func testResolvedAgentSessionReturnsMatchingSession() {
        let wordID = UUID()
        let session = AgentSession(
            wordID: wordID,
            persistence: AIContentViewPersistence(),
            snapshotProvider: AIContentViewSnapshotProvider(),
            generator: AIContentViewGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        let resolved = AIContentView.resolvedAgentSession(for: wordID, session: session)

        XCTAssertTrue(resolved === session)
    }

    func testResolvedAgentSessionRejectsSessionForDifferentWord() {
        let session = AgentSession(
            wordID: UUID(),
            persistence: AIContentViewPersistence(),
            snapshotProvider: AIContentViewSnapshotProvider(),
            generator: AIContentViewGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        let resolved = AIContentView.resolvedAgentSession(for: UUID(), session: session)

        XCTAssertNil(resolved)
    }

    func testResolvedChatPanelStatePrefersLLMUnavailableWhenNoModelConfigured() {
        XCTAssertEqual(
            AIContentView.resolvedChatPanelState(
                hasModel: false,
                itemID: UUID(),
                session: nil
            ),
            .llmUnavailable
        )
    }

    func testResolvedChatPanelStateUsesBusinessUnavailableWhenModelExistsButSessionIsMissing() {
        XCTAssertEqual(
            AIContentView.resolvedChatPanelState(
                hasModel: true,
                itemID: UUID(),
                session: nil
            ),
            .businessUnavailable
        )
    }

    func testResolvedChatPanelStateUsesReadyWhenMatchingSessionExists() {
        let wordID = UUID()
        let session = AgentSession(
            wordID: wordID,
            persistence: AIContentViewPersistence(),
            snapshotProvider: AIContentViewSnapshotProvider(),
            generator: AIContentViewGenerator(result: .init(text: "unused", tokensUsed: 1, durationMs: 1))
        )

        XCTAssertEqual(
            AIContentView.resolvedChatPanelState(
                hasModel: true,
                itemID: wordID,
                session: session
            ),
            .ready
        )
    }
}

private final class AIContentViewPersistence: AgentSessionPersisting {
    func upsertSession(for wordID: UUID, preferences: AgentSessionPreferences) throws -> AgentChatSession {
        AgentChatSession(wordItemID: wordID, preferences: preferences)
    }

    func session(for wordID: UUID) throws -> AgentChatSession? { nil }
    func loadMessages(sessionID: UUID) throws -> [AgentChatMessage] { [] }

    func addMessage(
        sessionID: UUID,
        role: AgentChatMessage.Role,
        status: AgentChatMessage.Status,
        content: MessageContent,
        createdAt: Date,
        supersededBy: UUID?,
        interrupted: Bool
    ) throws -> AgentChatMessage {
        AgentChatMessage(sessionID: sessionID, ordinal: 1, role: role, content: content)
    }

    func deleteMessages(ids: [UUID]) throws {}
    func clearMessages(sessionID: UUID) throws {}
    func resetSession(for wordID: UUID) throws {}

    func updateProposal(messageID: UUID, proposal: ProposalRecord) throws -> AgentChatMessage {
        AgentChatMessage(
            sessionID: UUID(),
            ordinal: 1,
            role: .assistant,
            content: .actionProposal(proposal)
        )
    }
}

private struct AIContentViewSnapshotProvider: AgentCardSnapshotProviding {
    func snapshot(for wordID: UUID) throws -> CardRenderSnapshot {
        CardRenderSnapshot(
            kind: .standard,
            word: "apple",
            phonetic: "/ˈæp.əl/",
            wireframe: "wireframe",
            structuredJSON: #"{"word":"apple"}"#,
            aiSectionOrder: []
        )
    }
}

private final class AIContentViewGenerator: AgentGenerating {
    private let result: GenerateResult

    init(result: GenerateResult) {
        self.result = result
    }

    func generate(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> GenerateResult {
        result
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private enum TestGenerationError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Generation failed."
    }
}
