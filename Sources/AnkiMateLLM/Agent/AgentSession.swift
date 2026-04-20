import AnkiMateRPC
import Combine
import DictKitAnkiExport
import Foundation

public protocol AgentSessionPersisting {
    func upsertSession(for wordID: UUID, preferences: AgentSessionPreferences) throws -> AgentChatSession
    func session(for wordID: UUID) throws -> AgentChatSession?
    func loadMessages(sessionID: UUID) throws -> [AgentChatMessage]
    func addMessage(
        sessionID: UUID,
        role: AgentChatMessage.Role,
        status: AgentChatMessage.Status,
        content: MessageContent,
        createdAt: Date,
        supersededBy: UUID?,
        interrupted: Bool
    ) throws -> AgentChatMessage
    func clearMessages(sessionID: UUID) throws
    func resetSession(for wordID: UUID) throws
    func updateProposal(messageID: UUID, proposal: ProposalRecord) throws -> AgentChatMessage
}

public extension AgentSessionPersisting {
    func upsertSession(for wordID: UUID) throws -> AgentChatSession {
        try upsertSession(for: wordID, preferences: .init())
    }

    func addMessage(
        sessionID: UUID,
        role: AgentChatMessage.Role,
        status: AgentChatMessage.Status = .completed,
        content: MessageContent,
        createdAt: Date = Date(),
        supersededBy: UUID? = nil,
        interrupted: Bool = false
    ) throws -> AgentChatMessage {
        try addMessage(
            sessionID: sessionID,
            role: role,
            status: status,
            content: content,
            createdAt: createdAt,
            supersededBy: supersededBy,
            interrupted: interrupted
        )
    }
}

public protocol AgentCardSnapshotProviding {
    func snapshot(for wordID: UUID) throws -> CardRenderSnapshot
}

public protocol AgentGenerating {
    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult
}

@MainActor
public final class AgentSession: ObservableObject {
    @Published public private(set) var sessionRecord: AgentChatSession?
    @Published public private(set) var messages: [AgentChatMessage] = []
    @Published public private(set) var pendingProposals: [ProposalRecord] = []
    @Published public var previewOverrideArtifacts: AIArtifacts?
    @Published public private(set) var isGenerating = false

    public let wordID: UUID

    private let persistence: AgentSessionPersisting
    private let snapshotProvider: AgentCardSnapshotProviding
    private let artifactsManager: AgentArtifactsManaging?
    private let generator: AgentGenerating
    private let promptBuilder: AgentPromptBuilder
    private let toolRegistry: AgentToolRegistry
    private let extraTools: [LLMToolDefinition]
    private let preferences: AgentSessionPreferences
    private let maxToolIterations: Int

    public init(
        wordID: UUID,
        persistence: AgentSessionPersisting,
        snapshotProvider: AgentCardSnapshotProviding,
        artifactsManager: AgentArtifactsManaging? = nil,
        generator: AgentGenerating,
        preferences: AgentSessionPreferences = .init(),
        promptBuilder: AgentPromptBuilder = .init(),
        tools: [LLMToolDefinition] = [],
        toolRegistry: AgentToolRegistry? = nil,
        maxToolIterations: Int = 4
    ) {
        let resolvedToolRegistry = toolRegistry ?? AgentToolRegistry(snapshotProvider: snapshotProvider)
        self.wordID = wordID
        self.persistence = persistence
        self.snapshotProvider = snapshotProvider
        self.artifactsManager = artifactsManager
        self.generator = generator
        self.preferences = preferences
        self.promptBuilder = promptBuilder
        self.toolRegistry = resolvedToolRegistry
        self.extraTools = tools
        self.maxToolIterations = maxToolIterations
    }

    public func reload() throws {
        let session = try persistence.upsertSession(for: wordID, preferences: preferences)
        let loadedMessages = try persistence.loadMessages(sessionID: session.id)
        sessionRecord = session
        messages = loadedMessages
        refreshDerivedState()
    }

    public func sendUserMessage(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if sessionRecord == nil {
            try reload()
        }
        guard let sessionRecord else {
            throw AgentSessionError.sessionUnavailable
        }

        let userMessage = try persistence.addMessage(
            sessionID: sessionRecord.id,
            role: .user,
            content: .text(trimmed)
        )
        messages.append(userMessage)
        refreshDerivedState()

        if let declinedKind = AgentCapabilityBoundaryClassifier.classify(trimmed) {
            let declinedMessage = try persistence.addMessage(
                sessionID: sessionRecord.id,
                role: .assistant,
                content: .layoutRequestDeclined(
                    userText: trimmed,
                    detectedKind: declinedKind
                )
            )
            messages.append(declinedMessage)
            refreshDerivedState()
            return
        }

        isGenerating = true
        defer { isGenerating = false }

        do {
            let snapshot = try snapshotProvider.snapshot(for: wordID)
            let availableTools = mergeTools()
            var toolIteration = 0

            while toolIteration <= maxToolIterations {
                let promptMessages = promptBuilder.buildMessages(
                    context: .init(
                        cardSnapshot: snapshot,
                        messages: messages,
                        tools: availableTools
                    )
                )
                let result = try await generator.generate(messages: promptMessages, tools: availableTools)

                if let toolCalls = result.toolCalls, !toolCalls.isEmpty {
                    let assistantText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !assistantText.isEmpty {
                        let assistantMessage = try persistence.addMessage(
                            sessionID: sessionRecord.id,
                            role: .assistant,
                            content: .text(assistantText)
                        )
                        messages.append(assistantMessage)
                    }

                    var shouldContinue = false
                    for toolCall in toolCalls {
                        let callMessage = try persistence.addMessage(
                            sessionID: sessionRecord.id,
                            role: .assistant,
                            content: .toolCall(
                                name: toolCall.name,
                                argsJSON: try encodeToolArguments(toolCall.arguments)
                            )
                        )
                        messages.append(callMessage)

                        let toolOutput = try toolRegistry.execute(toolCall, for: wordID)
                        let toolResultMessage = try persistence.addMessage(
                            sessionID: sessionRecord.id,
                            role: role(for: toolOutput),
                            content: toolOutput
                        )
                        messages.append(toolResultMessage)
                        if case .toolResult = toolOutput {
                            shouldContinue = true
                        }
                    }
                    refreshDerivedState()
                    if shouldContinue {
                        toolIteration += 1
                        continue
                    }
                    return
                }

                let assistantText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !assistantText.isEmpty else {
                    let emptyMessage = try persistence.addMessage(
                        sessionID: sessionRecord.id,
                        role: .assistant,
                        content: .error(message: "Agent returned an empty response.", recoverable: true)
                    )
                    messages.append(emptyMessage)
                    refreshDerivedState()
                    return
                }

                let assistantMessage = try persistence.addMessage(
                    sessionID: sessionRecord.id,
                    role: .assistant,
                    content: .text(assistantText)
                )
                messages.append(assistantMessage)
                refreshDerivedState()
                return
            }

            let toolLoopError = try persistence.addMessage(
                sessionID: sessionRecord.id,
                role: .assistant,
                content: .error(message: "Agent exceeded the tool-call limit for this turn.", recoverable: true)
            )
            messages.append(toolLoopError)
            refreshDerivedState()
        } catch {
            let errorMessage = try persistence.addMessage(
                sessionID: sessionRecord.id,
                role: .assistant,
                content: .error(message: error.localizedDescription, recoverable: true)
            )
            messages.append(errorMessage)
            refreshDerivedState()
        }
    }

    public func clearChat() throws {
        if sessionRecord == nil {
            try reload()
        }
        guard let sessionRecord else { return }
        try persistence.clearMessages(sessionID: sessionRecord.id)
        messages = []
        refreshDerivedState()
    }

    public func resetSession() throws {
        try persistence.resetSession(for: wordID)
        sessionRecord = nil
        messages = []
        previewOverrideArtifacts = nil
        refreshDerivedState()
    }

    public func setPreviewOverrideArtifacts(_ artifacts: AIArtifacts?) {
        previewOverrideArtifacts = artifacts
    }

    public func previewProposal(_ proposalID: UUID) throws {
        let proposal = try resolvePendingProposal(proposalID)
        guard let artifactsManager else {
            throw AgentSessionError.artifactsUnavailable
        }
        let artifacts = try artifactsManager.loadArtifacts(for: wordID)
        previewOverrideArtifacts = try AgentProposalArtifactsProjector.project(
            proposal: proposal,
            onto: artifacts,
            mode: .preview
        )
    }

    public func applyProposal(_ proposalID: UUID) throws {
        guard let artifactsManager else {
            throw AgentSessionError.artifactsUnavailable
        }
        let (messageIndex, proposal) = try locatePendingProposal(proposalID)
        let artifacts = try artifactsManager.loadArtifacts(for: wordID)
        let updatedArtifacts = try AgentProposalArtifactsProjector.project(
            proposal: proposal,
            onto: artifacts,
            mode: .persist
        )
        try artifactsManager.saveArtifacts(updatedArtifacts, for: wordID)

        var applied = proposal
        applied.decision = .applied
        applied.decidedAt = Date()
        let updatedMessage = try persistence.updateProposal(
            messageID: messages[messageIndex].id,
            proposal: applied
        )
        messages[messageIndex] = updatedMessage
        previewOverrideArtifacts = nil
        refreshDerivedState()
    }

    public func dismissProposal(_ proposalID: UUID) throws {
        let (messageIndex, proposal) = try locatePendingProposal(proposalID)
        var dismissed = proposal
        dismissed.decision = .dismissed
        dismissed.decidedAt = Date()
        let updatedMessage = try persistence.updateProposal(
            messageID: messages[messageIndex].id,
            proposal: dismissed
        )
        messages[messageIndex] = updatedMessage
        previewOverrideArtifacts = nil
        refreshDerivedState()
    }

    public func clearPreviewOverride() {
        previewOverrideArtifacts = nil
    }

    private func refreshDerivedState() {
        pendingProposals = messages.compactMap { message in
            guard case .actionProposal(let proposal) = message.content,
                  proposal.decision == .pending else {
                return nil
            }
            return proposal
        }
    }

    private func mergeTools() -> [LLMToolDefinition] {
        var merged: [LLMToolDefinition] = []
        var seen = Set<String>()

        for tool in toolRegistry.definitions + extraTools where seen.insert(tool.name).inserted {
            merged.append(tool)
        }

        return merged
    }

    private func encodeToolArguments(_ arguments: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(arguments)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentSessionError.invalidToolArguments
        }
        return json
    }

    private func role(for content: MessageContent) -> AgentChatMessage.Role {
        switch content {
        case .toolResult:
            return .tool
        case .actionProposal:
            return .assistant
        default:
            return .assistant
        }
    }

    private func resolvePendingProposal(_ proposalID: UUID) throws -> ProposalRecord {
        let (_, proposal) = try locatePendingProposal(proposalID)
        return proposal
    }

    private func locatePendingProposal(_ proposalID: UUID) throws -> (Int, ProposalRecord) {
        for (index, message) in messages.enumerated() {
            guard case .actionProposal(let proposal) = message.content,
                  proposal.id == proposalID,
                  proposal.decision == .pending else {
                continue
            }
            return (index, proposal)
        }
        throw AgentSessionError.proposalUnavailable
    }
}

public enum AgentSessionError: LocalizedError {
    case sessionUnavailable
    case invalidToolArguments
    case artifactsUnavailable
    case proposalUnavailable

    public var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return "Agent session is unavailable."
        case .invalidToolArguments:
            return "Agent emitted invalid tool arguments."
        case .artifactsUnavailable:
            return "Agent session cannot access word artifacts."
        case .proposalUnavailable:
            return "Agent proposal is unavailable."
        }
    }
}

private enum AgentCapabilityBoundaryClassifier {
    static func classify(_ text: String) -> DeclinedRequestKind? {
        let normalized = text.lowercased()

        if containsAny(normalized, keywords: [
            "template", "html", "css", "note type", "模板", "卡片模板", "html/css"
        ]) {
            return .template
        }

        if containsAny(normalized, keywords: [
            "style", "font", "fontsize", "font size", "spacing", "color", "颜色", "字号", "字体", "样式", "间距"
        ]) {
            return .style
        }

        if containsAny(normalized, keywords: [
            "layout", "section order", "move", "reorder", "before", "after",
            "布局", "顺序", "前面", "后面", "挪到", "移到", "放到", "位置"
        ]) {
            return .layout
        }

        return nil
    }

    private static func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
