import AnkiMateLLM
import AnkiMateRPC
import DictKitAnkiExport
import Foundation

struct AgentChatDisplayRow: Identifiable, Equatable {
    struct EmbeddedToolCall: Equatable {
        let name: String
        let argsJSON: String
    }

    let message: AgentChatMessage
    let embeddedToolCall: EmbeddedToolCall?

    var id: UUID { message.id }
}

enum AgentChatDisplayComposer {
    static func compose(_ messages: [AgentChatMessage]) -> [AgentChatDisplayRow] {
        var rows: [AgentChatDisplayRow] = []
        rows.reserveCapacity(messages.count)

        for index in messages.indices {
            if shouldHideToolCall(at: index, in: messages) {
                continue
            }

            rows.append(
                AgentChatDisplayRow(
                    message: messages[index],
                    embeddedToolCall: embeddedToolCall(at: index, in: messages)
                )
            )
        }

        return rows
    }

    private static func shouldHideToolCall(
        at index: Int,
        in messages: [AgentChatMessage]
    ) -> Bool {
        guard index + 1 < messages.count,
              case .toolCall(let name, _) = messages[index].content,
              case .actionProposal(let proposal) = messages[index + 1].content else {
            return false
        }

        return proposalToolName(for: proposal.kind) == name
    }

    private static func embeddedToolCall(
        at index: Int,
        in messages: [AgentChatMessage]
    ) -> AgentChatDisplayRow.EmbeddedToolCall? {
        guard index > 0,
              case .actionProposal(let proposal) = messages[index].content,
              case .toolCall(let name, let argsJSON) = messages[index - 1].content,
              proposalToolName(for: proposal.kind) == name else {
            return nil
        }

        return .init(name: name, argsJSON: argsJSON)
    }

    private static func proposalToolName(for kind: ProposalRecord.ProposalKind) -> String {
        switch kind {
        case .usageCue:
            return "propose_usage_cue"
        case .example:
            return "propose_example"
        case .recallDraft:
            return "propose_recall_draft"
        case .pitfall:
            return "propose_pitfall"
        case .mnemonic:
            return "propose_mnemonic"
        case .collocation:
            return "propose_collocation"
        case .deleteAccepted:
            return "propose_delete_accepted"
        }
    }
}

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

enum LLMAgentGenerationDefaults {
    static let maxTokens: Int? = nil
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
            parallelToolCalls: true,
            maxTokens: LLMAgentGenerationDefaults.maxTokens
        )
    }

    func generateStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: @escaping @Sendable (String) -> Void
    ) async throws -> GenerateResult {
        try await llmService.generateStreaming(
            messages: messages,
            tools: tools,
            parallelToolCalls: true,
            maxTokens: LLMAgentGenerationDefaults.maxTokens,
            onDelta: onDelta,
            onReasoningDelta: onReasoningDelta
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
