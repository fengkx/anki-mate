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
    func deleteMessages(ids: [UUID]) throws
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

public protocol AgentAttachmentStoring: AnyObject, Sendable {
    func data(for attachment: AgentAttachment) throws -> Data
    func delete(_ attachments: [AgentAttachment]) throws
    func deleteAllAttachments(for sessionID: UUID) throws
}

public protocol AgentGenerating {
    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult

    /// Streaming variant. Calls `onDelta` for content and `onReasoningDelta` for thinking.
    func generateStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: @escaping @Sendable (String) -> Void
    ) async throws -> GenerateResult
}

public extension AgentGenerating {
    func generateStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: @escaping @Sendable (String) -> Void
    ) async throws -> GenerateResult {
        try await generate(messages: messages, tools: tools)
    }
}

@MainActor
public final class AgentSession: ObservableObject {
    @Published public private(set) var sessionRecord: AgentChatSession?
    @Published public private(set) var messages: [AgentChatMessage] = []
    @Published public private(set) var pendingProposals: [ProposalRecord] = []
    @Published public var previewOverrideArtifacts: AIArtifacts?
    @Published public private(set) var isGenerating = false
    /// Live streaming text from the current generation. Empty when not streaming.
    @Published public private(set) var streamingText = ""
    /// Live streaming reasoning/thinking text. Empty when not streaming or model doesn't reason.
    @Published public private(set) var streamingReasoning = ""

    public let wordID: UUID

    private let persistence: AgentSessionPersisting
    private let snapshotProvider: AgentCardSnapshotProviding
    private let attachmentStore: AgentAttachmentStoring?
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
        attachmentStore: AgentAttachmentStoring? = nil,
        artifactsManager: AgentArtifactsManaging? = nil,
        generator: AgentGenerating,
        preferences: AgentSessionPreferences = .init(),
        promptBuilder: AgentPromptBuilder = .init(),
        tools: [LLMToolDefinition] = [],
        toolRegistry: AgentToolRegistry? = nil,
        maxToolIterations: Int = 4
    ) {
        let resolvedToolRegistry = toolRegistry ?? AgentToolRegistry(
            snapshotProvider: snapshotProvider,
            artifactsProvider: artifactsManager
        )
        self.wordID = wordID
        self.persistence = persistence
        self.snapshotProvider = snapshotProvider
        self.attachmentStore = attachmentStore
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

    public func sendUserMessage(_ text: String, attachments: [AgentAttachment] = []) async throws {
        try await sendUserMessage(text, attachments: attachments, deleteAttachmentsOnFailure: true)
    }

    private func sendUserMessage(
        _ text: String,
        attachments: [AgentAttachment],
        deleteAttachmentsOnFailure: Bool
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if sessionRecord == nil {
            try reload()
        }
        guard let sessionRecord else {
            throw AgentSessionError.sessionUnavailable
        }

        // Track message count before this turn so we can roll back on service errors.
        let messageCountBeforeTurn = messages.count

        let userMessage = try persistence.addMessage(
            sessionID: sessionRecord.id,
            role: .user,
            content: attachments.isEmpty ? .text(trimmed) : .userInput(text: trimmed, attachments: attachments)
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
        defer {
            isGenerating = false
            streamingText = ""
            streamingReasoning = ""
        }

        do {
            try await runAssistantTurn(sessionID: sessionRecord.id)
        } catch {
            // Model service errors should not pollute the conversation context.
            // Roll back all messages added during this turn (including the user message)
            // so the user can simply re-send.
            try rollbackMessages(from: messageCountBeforeTurn)
            if deleteAttachmentsOnFailure {
                try? attachmentStore?.delete(attachments)
            }
            throw error
        }
    }

    /// Edit the last user message and regenerate. The previous turn stays intact until the
    /// replacement request succeeds, so transient failures do not destroy chat history.
    public func editLastUserMessage(_ newText: String) async throws {
        guard sessionRecord != nil else {
            throw AgentSessionError.sessionUnavailable
        }

        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return
        }
        let attachments = userAttachments(in: messages[lastUserIndex].content)

        let messagesToReplace = Array(messages[lastUserIndex...])
        let retainedMessages = Array(messages[..<lastUserIndex])

        try await withTemporaryTranscript(retainedMessages, deletingOnSuccess: messagesToReplace) {
            try await sendUserMessage(newText, attachments: attachments, deleteAttachmentsOnFailure: false)
        }
    }

    /// Regenerate the last assistant response while keeping the existing reply available until
    /// the retry succeeds.
    public func regenerateLastResponse() async throws {
        guard let sessionRecord else {
            throw AgentSessionError.sessionUnavailable
        }

        // Find the last user message
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }),
              messages[lastUserIndex].content.isUserAuthoredInput else {
            return
        }

        let assistantMessagesToReplace = Array(messages[(lastUserIndex + 1)...])
        let retainedMessages = Array(messages[...lastUserIndex])

        try await withTemporaryTranscript(retainedMessages, deletingOnSuccess: assistantMessagesToReplace) {
            try await regenerateFromCurrentTranscript(sessionID: sessionRecord.id)
        }
    }

    public func clearChat() throws {
        if sessionRecord == nil {
            try reload()
        }
        guard let sessionRecord else { return }
        try persistence.clearMessages(sessionID: sessionRecord.id)
        try attachmentStore?.deleteAllAttachments(for: sessionRecord.id)
        messages = []
        refreshDerivedState()
    }

    public func resetSession() throws {
        if let sessionRecord {
            try attachmentStore?.deleteAllAttachments(for: sessionRecord.id)
        }
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
            mode: .preview
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

    private func generateWithStreaming(
        promptMessages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult {
        streamingText = ""
        streamingReasoning = ""
        let accumulator = StreamingDeltaAccumulator { [weak self] text, reasoning in
            self?.streamingText += text
            self?.streamingReasoning += reasoning
        }
        defer {
            accumulator.close()
        }
        let result = try await generator.generateStreaming(
            messages: promptMessages,
            tools: tools,
            onDelta: { delta in
                accumulator.append(content: delta)
            },
            onReasoningDelta: { delta in
                accumulator.append(reasoning: delta)
            }
        )
        await accumulator.flushAndClose()
        return result
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

    private func withTemporaryTranscript<T>(
        _ temporaryMessages: [AgentChatMessage],
        deletingOnSuccess replacedMessages: [AgentChatMessage],
        operation: () async throws -> T
    ) async throws -> T {
        let originalMessages = messages
        messages = temporaryMessages
        refreshDerivedState()

        do {
            let result = try await operation()
            let idsToDelete = replacedMessages.map(\.id)
            if !idsToDelete.isEmpty {
                try persistence.deleteMessages(ids: idsToDelete)
            }
            refreshDerivedState()
            return result
        } catch {
            messages = originalMessages
            refreshDerivedState()
            throw error
        }
    }

    private func regenerateFromCurrentTranscript(sessionID: UUID) async throws {
        isGenerating = true
        defer {
            isGenerating = false
            streamingText = ""
            streamingReasoning = ""
        }

        let messageCountBeforeRegen = messages.count

        do {
            try await runAssistantTurn(sessionID: sessionID)
        } catch {
            try rollbackMessages(from: messageCountBeforeRegen)
            throw error
        }
    }

    private func runAssistantTurn(sessionID: UUID) async throws {
        let snapshot = try snapshotProvider.snapshot(for: wordID)
        let availableTools = mergeTools()
        var toolIteration = 0

        while toolIteration <= maxToolIterations {
            let promptMessages = promptBuilder.buildMessages(
                context: .init(
                    cardSnapshot: snapshot,
                    messages: messages,
                    tools: availableTools,
                    attachmentStore: attachmentStore
                )
            )
            let result = try await generateWithStreaming(promptMessages: promptMessages, tools: availableTools)

            if let toolCalls = result.toolCalls, !toolCalls.isEmpty {
                try persistAssistantTextIfPresent(result, sessionID: sessionID)

                // Once the visible assistant text is persisted, switch the bottom-row
                // indicator back to a loading state while tool calls are being resolved.
                streamingText = ""
                streamingReasoning = ""

                let shouldContinue = try executeToolCalls(toolCalls, sessionID: sessionID)
                refreshDerivedState()
                if shouldContinue {
                    toolIteration += 1
                    continue
                }
                return
            }

            try persistFinalAssistantResponse(result, sessionID: sessionID)
            return
        }

        let toolLoopError = try persistence.addMessage(
            sessionID: sessionID,
            role: .assistant,
            content: .error(message: "Agent exceeded the tool-call limit for this turn.", recoverable: true)
        )
        messages.append(toolLoopError)
        refreshDerivedState()
    }

    private func persistAssistantTextIfPresent(_ result: GenerateResult, sessionID: UUID) throws {
        let assistantText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantText.isEmpty else { return }
        let assistantMessage = try persistence.addMessage(
            sessionID: sessionID,
            role: .assistant,
            content: .text(assistantText, reasoning: result.reasoning)
        )
        messages.append(assistantMessage)
    }

    private func persistFinalAssistantResponse(_ result: GenerateResult, sessionID: UUID) throws {
        let assistantText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assistantText.isEmpty else {
            let emptyMessage = try persistence.addMessage(
                sessionID: sessionID,
                role: .assistant,
                content: .error(message: "Agent returned an empty response.", recoverable: true)
            )
            messages.append(emptyMessage)
            refreshDerivedState()
            return
        }

        let assistantMessage = try persistence.addMessage(
            sessionID: sessionID,
            role: .assistant,
            content: .text(assistantText, reasoning: result.reasoning)
        )
        messages.append(assistantMessage)
        refreshDerivedState()
    }

    private func executeToolCalls(_ toolCalls: [LLMToolCall], sessionID: UUID) throws -> Bool {
        var shouldContinue = false
        for rawToolCall in toolCalls {
            let toolCall = try toolRegistry.normalizedToolCall(rawToolCall, for: wordID)
            let callMessage = try persistence.addMessage(
                sessionID: sessionID,
                role: .assistant,
                content: .toolCall(
                    name: toolCall.name,
                    argsJSON: try encodeToolArguments(toolCall.arguments)
                )
            )
            messages.append(callMessage)

            let toolOutput = try toolRegistry.execute(toolCall, for: wordID)
            let toolResultMessage = try persistence.addMessage(
                sessionID: sessionID,
                role: role(for: toolOutput),
                content: toolOutput
            )
            messages.append(toolResultMessage)
            if case .toolResult = toolOutput {
                shouldContinue = true
            }
        }
        return shouldContinue
    }

    private func rollbackMessages(from startIndex: Int) throws {
        guard startIndex < messages.count else { return }
        let idsToDelete = messages[startIndex...].map(\.id)
        try persistence.deleteMessages(ids: idsToDelete)
        messages.removeSubrange(startIndex...)
        refreshDerivedState()
    }

    private func userAttachments(in content: MessageContent) -> [AgentAttachment] {
        guard case .userInput(_, let attachments) = content else { return [] }
        return attachments
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

private final class StreamingDeltaAccumulator: @unchecked Sendable {
    typealias Apply = @MainActor (_ content: String, _ reasoning: String) -> Void

    private let lock = NSLock()
    private let apply: Apply
    private var pendingContent = ""
    private var pendingReasoning = ""
    private var flushTask: Task<Void, Never>?
    private var isClosed = false

    init(apply: @escaping Apply) {
        self.apply = apply
    }

    func append(content: String = "", reasoning: String = "") {
        guard !content.isEmpty || !reasoning.isEmpty else { return }
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }

        pendingContent += content
        pendingReasoning += reasoning
        if flushTask == nil {
            flushTask = Task { [weak self] in
                await self?.flushLoop()
            }
        }
        lock.unlock()
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }

    func flushAndClose() async {
        close()
        while true {
            let task = currentFlushTask()
            guard let task else { break }
            await task.value
        }

        let batch = takePending()
        if !batch.content.isEmpty || !batch.reasoning.isEmpty {
            await apply(batch.content, batch.reasoning)
        }
    }

    private func flushLoop() async {
        while true {
            let batch = takePending()
            if batch.content.isEmpty && batch.reasoning.isEmpty {
                let shouldRestart = finishFlushTaskAndCheckForPending()
                if shouldRestart {
                    continue
                }
                return
            }
            await apply(batch.content, batch.reasoning)
        }
    }

    private func currentFlushTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return flushTask
    }

    private func finishFlushTaskAndCheckForPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        flushTask = nil
        let shouldRestart = !pendingContent.isEmpty || !pendingReasoning.isEmpty
        if shouldRestart {
            flushTask = Task { [weak self] in
                await self?.flushLoop()
            }
        }
        return shouldRestart
    }

    private func takePending() -> (content: String, reasoning: String) {
        lock.lock()
        defer { lock.unlock() }
        let content = pendingContent
        let reasoning = pendingReasoning
        pendingContent = ""
        pendingReasoning = ""
        return (content, reasoning)
    }
}
