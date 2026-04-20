import AnkiMateLLM
import AnkiMateRPC
import DictKitAnkiExport
import Foundation

final class WordItemAgentBridge: AgentCardSnapshotProviding, AgentArtifactsManaging {
    enum SnapshotMode {
        case standard
        case recall
    }

    private let item: WordItem
    private let viewModel: WordListViewModel
    private let snapshotMode: @Sendable () -> SnapshotMode

    init(
        item: WordItem,
        viewModel: WordListViewModel,
        snapshotMode: @escaping @Sendable () -> SnapshotMode
    ) {
        self.item = item
        self.viewModel = viewModel
        self.snapshotMode = snapshotMode
    }

    nonisolated func snapshot(for wordID: UUID) throws -> CardRenderSnapshot {
        try MainActor.assumeIsolated {
            guard wordID == item.id else {
                throw AgentBridgeError.wordMismatch
            }
            guard let result = item.lookupResult else {
                throw AgentBridgeError.lookupUnavailable
            }

            switch snapshotMode() {
            case .standard:
                return CardRenderSnapshotBuilder.standard(
                    word: item.word,
                    lookupResult: result,
                    aiArtifacts: item.aiArtifacts
                )
            case .recall:
                return CardRenderSnapshotBuilder.recall(
                    word: item.word,
                    lookupResult: result,
                    aiArtifacts: item.aiArtifacts
                )
            }
        }
    }

    nonisolated func loadArtifacts(for wordID: UUID) throws -> AIArtifacts {
        try MainActor.assumeIsolated {
            guard wordID == item.id else {
                throw AgentBridgeError.wordMismatch
            }
            return item.aiArtifacts
        }
    }

    nonisolated func saveArtifacts(_ artifacts: AIArtifacts, for wordID: UUID) throws {
        try MainActor.assumeIsolated {
            guard wordID == item.id else {
                throw AgentBridgeError.wordMismatch
            }
            viewModel.saveAIArtifacts(artifacts, for: item)
        }
    }
}

@MainActor
final class LLMAgentGeneratorAdapter: AgentGenerating {
    private let llmService: LLMService

    init(llmService: LLMService) {
        self.llmService = llmService
    }

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult {
        try await llmService.generate(
            messages: messages,
            tools: tools,
            parallelToolCalls: true
        )
    }
}

enum AgentBridgeError: LocalizedError {
    case wordMismatch
    case lookupUnavailable

    var errorDescription: String? {
        switch self {
        case .wordMismatch:
            return "Agent bridge is bound to a different word."
        case .lookupUnavailable:
            return "Dictionary lookup is not ready for this word."
        }
    }
}
