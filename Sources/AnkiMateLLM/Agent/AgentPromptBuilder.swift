import AnkiMateRPC
import DictKitAnkiExport
import Foundation

public struct AgentPromptBuilder {
    public struct Configuration: Sendable, Equatable {
        public var recentMessageLimit: Int
        public var guaranteedRecentMessages: Int
        public var maxContextTokens: Int
        public var pendingProposalSummaryLimit: Int
        public var decisionSummaryLimit: Int

        public init(
            recentMessageLimit: Int = 12,
            guaranteedRecentMessages: Int = 5,
            maxContextTokens: Int = 3_500,
            pendingProposalSummaryLimit: Int = 6,
            decisionSummaryLimit: Int = 8
        ) {
            self.recentMessageLimit = recentMessageLimit
            self.guaranteedRecentMessages = guaranteedRecentMessages
            self.maxContextTokens = maxContextTokens
            self.pendingProposalSummaryLimit = pendingProposalSummaryLimit
            self.decisionSummaryLimit = decisionSummaryLimit
        }
    }

    public struct Context: Sendable, Equatable {
        public let cardSnapshot: CardRenderSnapshot
        public let messages: [AgentChatMessage]
        public let tools: [LLMToolDefinition]
        public let maxContextTokens: Int?

        public init(
            cardSnapshot: CardRenderSnapshot,
            messages: [AgentChatMessage],
            tools: [LLMToolDefinition] = [],
            maxContextTokens: Int? = nil
        ) {
            self.cardSnapshot = cardSnapshot
            self.messages = messages
            self.tools = tools
            self.maxContextTokens = maxContextTokens
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func buildMessages(context: Context) -> [LLMMessage] {
        let responseLanguage = detectResponseLanguage(in: context.messages)
        let identityPrompt = buildIdentityPrompt(
            responseLanguage: responseLanguage,
            tools: context.tools
        )
        let contextPrompt = buildContextPrompt(
            snapshot: context.cardSnapshot,
            messages: context.messages
        )

        let reservedBudget = approximateTokenCount(identityPrompt) + approximateTokenCount(contextPrompt)
        let totalBudget = context.maxContextTokens ?? configuration.maxContextTokens
        let historyBudget = max(0, totalBudget - reservedBudget)
        let historyMessages = assembleHistoryMessages(
            from: context.messages,
            tokenBudget: historyBudget
        )

        return [
            LLMMessage(role: .system, content: identityPrompt),
            LLMMessage(role: .system, content: contextPrompt),
        ] + historyMessages
    }

    func assembleHistoryMessages(
        from messages: [AgentChatMessage],
        tokenBudget: Int
    ) -> [LLMMessage] {
        let visible = messages
            .filter { $0.supersededBy == nil }
            .sorted { $0.ordinal < $1.ordinal }

        let recentCount = min(configuration.recentMessageLimit, visible.count)
        let recentMessages = Array(visible.suffix(recentCount))
        let olderMessages = Array(visible.dropLast(recentCount))

        var history = olderMessages
            .filter { message in
                if case .summary = message.content {
                    return true
                }
                return false
            }
            .map(renderHistoryMessage)
            + recentMessages.map(renderHistoryMessage)

        trimHistory(&history, tokenBudget: tokenBudget)
        return history
    }

    private func trimHistory(
        _ history: inout [LLMMessage],
        tokenBudget: Int
    ) {
        guard tokenBudget > 0 else {
            history = Array(history.suffix(configuration.guaranteedRecentMessages))
            return
        }

        while approximateTokenCount(history) > tokenBudget {
            if let firstSummaryIndex = history.firstIndex(where: { $0.content.hasPrefix("Summary of earlier discussion") }) {
                history.remove(at: firstSummaryIndex)
                continue
            }

            if history.count > configuration.guaranteedRecentMessages {
                history.removeFirst()
                continue
            }

            history = history.enumerated().map { index, message in
                guard index < history.count - 1 else { return message }
                return LLMMessage(role: message.role, content: truncated(message.content, maxCharacters: 160))
            }

            if approximateTokenCount(history) <= tokenBudget {
                break
            }

            history = Array(history.suffix(configuration.guaranteedRecentMessages))
            break
        }
    }

    private func buildIdentityPrompt(
        responseLanguage: ResponseLanguage,
        tools: [LLMToolDefinition]
    ) -> String {
        PromptText.join([
            // Primary identity — what you are
            "You are my study assistant for Anki vocabulary cards. I'm reviewing a card and may ask you questions or request edits.",

            // Default behavior — just talk
            """
            Most of the time, just answer my question directly in the chat. Explain word usage, nuance, differences, etymology — whatever I ask. Keep it concise and useful for memorization.
            """,

            // When to use tools — only for card edits
            tools.isEmpty ? nil : """
            You also have tools to propose content edits to my card (examples, usage cues, pitfalls, mnemonics, collocations, recall drafts). Only use these tools when I explicitly ask you to change, add, or remove something on the card. If I'm just asking a question, answer in text — do not call any tool.
            """,

            // Scope limits
            "You can only edit card content. Layout, style, fonts, colors, and template changes are not supported.",

            // Language
            responseLanguage.directive,

            // Tool list (if any)
            toolInstructionBlock(from: tools)
        ])
    }

    private func buildContextPrompt(
        snapshot: CardRenderSnapshot,
        messages: [AgentChatMessage]
    ) -> String {
        let pendingSummary = pendingProposalSummary(from: messages)
        let decisionSummary = decisionSummary(from: messages)

        return PromptText.join([
            "Current card snapshot",
            PromptText.labeledBlock("ASCII wireframe", value: snapshot.wireframe),
            PromptText.labeledBlock("Structured JSON", value: snapshot.structuredJSON),
            pendingSummary.map { PromptText.labeledBlock("Pending proposals", value: $0) },
            decisionSummary.map { PromptText.labeledBlock("Recent proposal decisions", value: $0) }
        ])
    }

    private func pendingProposalSummary(from messages: [AgentChatMessage]) -> String? {
        let pending = proposalMessages(in: messages)
            .filter { $0.proposal.decision == .pending }
            .suffix(configuration.pendingProposalSummaryLimit)

        guard !pending.isEmpty else { return nil }
        return pending.map { row in
            "- \(row.proposal.kind.rawValue) \(operationSummary(row.proposal.operation)): \(row.proposal.diffSummary)"
        }.joined(separator: "\n")
    }

    private func decisionSummary(from messages: [AgentChatMessage]) -> String? {
        let decided = proposalMessages(in: messages)
            .filter { $0.proposal.decision != .pending }
            .suffix(configuration.decisionSummaryLimit)

        guard !decided.isEmpty else { return nil }
        return decided.map { row in
            "- \(row.proposal.decision.rawValue) \(row.proposal.kind.rawValue): \(row.proposal.diffSummary)"
        }.joined(separator: "\n")
    }

    private func proposalMessages(in messages: [AgentChatMessage]) -> [(message: AgentChatMessage, proposal: ProposalRecord)] {
        messages.compactMap { message in
            guard message.supersededBy == nil else { return nil }
            guard case .actionProposal(let proposal) = message.content else { return nil }
            return (message, proposal)
        }
    }

    private func renderHistoryMessage(_ message: AgentChatMessage) -> LLMMessage {
        LLMMessage(
            role: llmRole(for: message.role),
            content: renderedContent(for: message.content)
        )
    }

    private func llmRole(for role: AgentChatMessage.Role) -> LLMMessageRole {
        switch role {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .tool:
            return .tool
        case .system:
            return .system
        }
    }

    private func renderedContent(for content: MessageContent) -> String {
        switch content {
        case .text(let text, _):
            return text
        case .toolCall(let name, let argsJSON):
            return PromptText.join([
                "[Tool call] \(name)",
                argsJSON
            ])
        case .toolResult(let name, let resultJSON, let truncated):
            return PromptText.join([
                "[Tool result] \(name)\(truncated ? " (truncated)" : "")",
                resultJSON
            ])
        case .actionProposal(let proposal):
            return PromptText.join([
                "Proposal (\(proposal.decision.rawValue))",
                "Kind: \(proposal.kind.rawValue)",
                "Operation: \(operationSummary(proposal.operation))",
                "Summary: \(proposal.diffSummary)",
                proposal.rationale.map { "Rationale: \($0)" }
            ])
        case .summary(let text, let supersededCount):
            return "Summary of earlier discussion (supersedes \(supersededCount) messages): \(text)"
        case .error(let message, let recoverable):
            return "Error (\(recoverable ? "recoverable" : "fatal")): \(message)"
        case .layoutRequestDeclined(let userText, let detectedKind):
            return "Declined \(detectedKind.rawValue) request: \(userText)"
        }
    }

    private func operationSummary(_ operation: ProposalRecord.Operation) -> String {
        switch operation {
        case .add:
            return "add"
        case .replace(let targetID):
            return "replace \(targetID)"
        case .delete(let targetID):
            return "delete \(targetID)"
        }
    }

    private func toolInstructionBlock(from tools: [LLMToolDefinition]) -> String? {
        guard !tools.isEmpty else { return nil }
        let lines = tools.map { tool in
            if let description = tool.description, !description.isEmpty {
                return "- \(tool.name): \(description)"
            }
            return "- \(tool.name)"
        }
        return PromptText.labeledBlock("Available tools", value: lines.joined(separator: "\n"))
    }

    private func detectResponseLanguage(in messages: [AgentChatMessage]) -> ResponseLanguage {
        let recentUserTexts = messages
            .sorted { $0.ordinal > $1.ordinal }
            .compactMap { message -> String? in
                guard message.role == .user else { return nil }
                guard case .text(let text, _) = message.content else { return nil }
                return text
            }
            .prefix(3)

        for text in recentUserTexts where containsHan(text) {
            return .simplifiedChinese
        }
        return .english
    }

    private func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF:
                return true
            default:
                return false
            }
        }
    }

    private func approximateTokenCount(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private func approximateTokenCount(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { partial, message in
            partial + approximateTokenCount(message.content) + 4
        }
    }

    private func truncated(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<end]) + "…"
    }
}

private enum ResponseLanguage {
    case simplifiedChinese
    case english

    var directive: String {
        switch self {
        case .simplifiedChinese:
            return "Respond in Simplified Chinese unless the user clearly switches languages."
        case .english:
            return "Respond in English unless the user clearly switches languages."
        }
    }
}

private enum PromptText {
    static func join(_ sections: [String?]) -> String {
        sections
            .compactMap { section in
                guard let section else { return nil }
                let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n\n")
    }

    static func labeledBlock(_ title: String, value: String) -> String {
        "\(title):\n\(value)"
    }
}
