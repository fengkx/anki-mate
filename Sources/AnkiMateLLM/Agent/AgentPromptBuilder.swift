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

    public struct Context: Sendable {
        public let cardSnapshot: CardRenderSnapshot
        public let relatedSnapshots: [CardRenderSnapshot]
        public let messages: [AgentChatMessage]
        public let tools: [LLMToolDefinition]
        public let maxContextTokens: Int?
        public let attachmentStore: AgentAttachmentStoring?

        public init(
            cardSnapshot: CardRenderSnapshot,
            relatedSnapshots: [CardRenderSnapshot] = [],
            messages: [AgentChatMessage],
            tools: [LLMToolDefinition] = [],
            maxContextTokens: Int? = nil,
            attachmentStore: AgentAttachmentStoring? = nil
        ) {
            self.cardSnapshot = cardSnapshot
            self.relatedSnapshots = relatedSnapshots
            self.messages = messages
            self.tools = tools
            self.maxContextTokens = maxContextTokens
            self.attachmentStore = attachmentStore
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
            relatedSnapshots: context.relatedSnapshots,
            messages: context.messages
        )

        let reservedBudget = approximateTokenCount(identityPrompt) + approximateTokenCount(contextPrompt)
        let totalBudget = context.maxContextTokens ?? configuration.maxContextTokens
        let historyBudget = max(0, totalBudget - reservedBudget)
        let historyMessages = assembleHistoryMessages(
            from: context.messages,
            tokenBudget: historyBudget,
            attachmentStore: context.attachmentStore
        )

        return [
            LLMMessage(
                role: .system,
                content: PromptText.join([
                    identityPrompt,
                    contextPrompt
                ])
            ),
        ] + historyMessages
    }

    func assembleHistoryMessages(
        from messages: [AgentChatMessage],
        tokenBudget: Int,
        attachmentStore: AgentAttachmentStoring? = nil
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
            .map { renderHistoryMessage($0, attachmentStore: nil) }
            + recentMessages.map { renderHistoryMessage($0, attachmentStore: attachmentStore) }

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
            if let firstSummaryIndex = history.firstIndex(where: { $0.content.plainText.hasPrefix("Summary of earlier discussion") }) {
                history.remove(at: firstSummaryIndex)
                continue
            }

            if history.count > configuration.guaranteedRecentMessages {
                history.removeFirst()
                continue
            }

            history = history.enumerated().map { index, message in
                guard index < history.count - 1 else { return message }
                return LLMMessage(role: message.role, content: truncated(message.content.plainText, maxCharacters: 160))
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

            Card edit policy:
            - First decide whether the user is asking about the word or asking to edit card content.
            - For explanation, nuance, etymology, usage, or comparison questions, answer in chat and do not call tools.
            - The current card headword is the default learning target for study and edit requests. If the user asks to add learning content without naming another target, do not ask which word or aspect the user means.
            - Attached images and existing artifacts are evidence for the current card, not alternative learning targets. Use them to infer style, section, and learning gaps; do not treat incidental words inside them as competing topics.
            - Existing artifacts can still be edit targets for replace/delete when the user refers to them; use their real artifact ids for targetID.
            - First infer the learner's immediate task from the user's request and the card context.
            - Prefer the information that most directly helps the learner succeed at that immediate task.
            - When the learner is trying to distinguish, recall, choose, fill, or avoid an error, give discriminative help instead of broad background explanation.
            - Do not drift into adjacent knowledge unless it clearly improves success on the learner's immediate task.
            - When the user mentions a Recall Card, cloze, blank, hidden letters, front/back, or 挖空, use the Recall Card snapshot already in context as the source of truth for the actual hidden position and answer.
            - For Recall Card questions, first identify the exact masked token and the hidden letters from the Recall snapshot before explaining anything else.
            - When the hidden letters can be derived from the Recall snapshot, state them explicitly in the first sentence. Example: `当前挖空是 per__tual，缺的是 pe。`
            - If the user asks for a mnemonic, 记忆点, or memory trick to help solve a Recall Card blank, answer in chat by default. Do not call propose_mnemonic unless the user explicitly asks to add that mnemonic to the standard card.
            - Mnemonic proposals are for visible standard-card learning content. They are not the default response for Recall Card coaching, hidden-letter explanation, or blank-solving help.
            - If the user explicitly asks to change the Recall Card itself, prefer propose_recall_draft rather than propose_mnemonic.
            - For content edit requests, call the matching propose_* tool as soon as the action, section, and content can be inferred from the current card or recent conversation.
            - Treat references to earlier suggestions, numbered items, the most recent candidate, current pending proposals, or existing card sections as usable context. Do not ask the user to repeat information already present in the conversation.
            - Proposal cards are the confirmation step. Do not ask the user to confirm before creating a proposal; the user will Apply or Dismiss it.
            - Ask a clarifying question only when multiple plausible interpretations would produce different card edits.
            - For underspecified content edit requests, make a constructive best-effort proposal first. This applies to examples, usage cues, pitfalls, mnemonics, collocations, and recall drafts.
            - Default to generating the content yourself unless the user explicitly requests sourced/cited/verbatim content. Treat provenance/style preferences as optional refinements, not blockers.
            - Do not ask the user to choose between internal labels or categories before creating a proposal. Use a reasonable default that fits the current card and let the user refine after reviewing the proposal.
            - Do not ask for preferred scene, context, focus, tone, or angle before creating a proposal when a reasonable default can be inferred from the current card.
            - You may ask a follow-up after the proposal is shown, or mention that the user can ask for a different angle after reviewing it.

            Tool argument contract:
            - operation=add must not include targetID because it creates new content.
            - When adding an example without exact text, generate a useful example for the current headword yourself and propose it.
            - Recall draft proposals still use the same top-level contract: include operation at the top level, then put mode/front/back/hint inside payload.
            - Example recall-draft tool call: {"operation":"add","payload":{"mode":"targeted_letter_cloze","front":"per__tual","back":"perpetual","hint":"形容词 · 无休止的"}}
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
        relatedSnapshots: [CardRenderSnapshot],
        messages: [AgentChatMessage]
    ) -> String {
        let pendingSummary = pendingProposalSummary(from: messages)
        let decisionSummary = decisionSummary(from: messages)

        return PromptText.join([
            "Current card snapshot",
            PromptText.labeledBlock("ASCII wireframe", value: snapshot.wireframe),
            PromptText.labeledBlock("Structured JSON", value: snapshot.structuredJSON),
            recallFocusSummaryText(currentSnapshot: snapshot, relatedSnapshots: relatedSnapshots),
            relatedSnapshotsText(relatedSnapshots),
            pendingSummary.map { PromptText.labeledBlock("Pending proposals", value: $0) },
            decisionSummary.map { PromptText.labeledBlock("Recent proposal decisions", value: $0) }
        ])
    }

    private func recallFocusSummaryText(
        currentSnapshot: CardRenderSnapshot,
        relatedSnapshots: [CardRenderSnapshot]
    ) -> String? {
        let candidates = [("current", currentSnapshot)] + relatedSnapshots.enumerated().map { ("related-\($0.offset + 1)", $0.element) }
        let summaries = candidates.compactMap { source, snapshot in
            recallSummary(for: snapshot, source: source)
        }
        guard !summaries.isEmpty else { return nil }
        return PromptText.labeledBlock(
            "Recall focus summary",
            value: summaries.joined(separator: "\n\n")
        )
    }

    private func recallSummary(for snapshot: CardRenderSnapshot, source: String) -> String? {
        guard snapshot.kind == .recall else { return nil }
        guard let jsonObject = structuredJSONObject(from: snapshot.structuredJSON),
              let recall = jsonObject["recall"] as? [String: Any] else {
            return nil
        }

        let front = recall["front"] as? String
        let back = recall["back"] as? String
        let mode = recall["mode"] as? String
        let hint = recall["hint"] as? String
        let maskedToken = front.flatMap { extractMaskedToken(in: $0, expectedLength: back?.count) }
        let derivedHiddenSegment: String?
        if let maskedToken, let back {
            derivedHiddenSegment = deriveHiddenSegment(maskedToken: maskedToken, answer: back)
        } else {
            derivedHiddenSegment = nil
        }

        return PromptText.join([
            "Source: \(source)",
            front.map { "front: \($0)" },
            back.map { "back: \($0)" },
            mode.map { "mode: \($0)" },
            hint.map { "hint: \($0)" },
            maskedToken.map { "masked token: \($0)" },
            derivedHiddenSegment.map { "hidden segment: \($0)" }
        ])
    }

    private func structuredJSONObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func extractMaskedToken(in front: String, expectedLength: Int?) -> String? {
        let tokens = front
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { $0.contains("_") }

        if let expectedLength {
            return tokens.first(where: { $0.count == expectedLength }) ?? tokens.first
        }
        return tokens.first
    }

    private func deriveHiddenSegment(maskedToken: String, answer: String) -> String? {
        let maskedChars = Array(maskedToken)
        let answerChars = Array(answer)
        guard maskedChars.count == answerChars.count else { return nil }

        var hidden: [Character] = []
        var seenMask = false
        var gapClosed = false

        for (maskedChar, answerChar) in zip(maskedChars, answerChars) {
            if maskedChar == "_" {
                if gapClosed { return nil }
                seenMask = true
                hidden.append(answerChar)
                continue
            }

            if seenMask, !hidden.isEmpty {
                gapClosed = true
            }

            guard maskedChar == answerChar else { return nil }
        }

        guard seenMask, !hidden.isEmpty else { return nil }
        return String(hidden)
    }

    private func relatedSnapshotsText(_ snapshots: [CardRenderSnapshot]) -> String? {
        guard !snapshots.isEmpty else { return nil }
        let rendered = snapshots.map { snapshot in
            PromptText.join([
                "Snapshot kind: \(snapshot.kind.rawValue)",
                PromptText.labeledBlock("ASCII wireframe", value: snapshot.wireframe),
                PromptText.labeledBlock("Structured JSON", value: snapshot.structuredJSON)
            ])
        }.joined(separator: "\n\n")
        return PromptText.labeledBlock("Related card snapshots", value: rendered)
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

    private func renderHistoryMessage(
        _ message: AgentChatMessage,
        attachmentStore: AgentAttachmentStoring?
    ) -> LLMMessage {
        LLMMessage(
            role: llmRole(for: message.role),
            content: renderedContent(for: message.content, attachmentStore: attachmentStore)
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

    private func renderedContent(
        for content: MessageContent,
        attachmentStore: AgentAttachmentStoring?
    ) -> LLMMessageContent {
        switch content {
        case .text(let text, _):
            return .text(text)
        case .userInput(let text, let attachments):
            return userInputContent(text: text, attachments: attachments, attachmentStore: attachmentStore)
        case .toolCall(let name, let argsJSON):
            return .text(PromptText.join([
                "Assistant used tool: \(name)",
                "Tool arguments JSON:",
                argsJSON
            ]))
        case .toolResult(let name, let resultJSON, let truncated):
            return .text(PromptText.join([
                "Tool result from \(name)\(truncated ? " (truncated)" : ""):",
                resultJSON
            ]))
        case .actionProposal(let proposal):
            return .text(PromptText.join([
                "Proposal (\(proposal.decision.rawValue))",
                "Kind: \(proposal.kind.rawValue)",
                "Operation: \(operationSummary(proposal.operation))",
                "Summary: \(proposal.diffSummary)",
                proposal.rationale.map { "Rationale: \($0)" }
            ]))
        case .summary(let text, let supersededCount):
            return .text("Summary of earlier discussion (supersedes \(supersededCount) messages): \(text)")
        case .error(let message, let recoverable):
            return .text("Error (\(recoverable ? "recoverable" : "fatal")): \(message)")
        case .layoutRequestDeclined(let userText, let detectedKind):
            return .text("Declined \(detectedKind.rawValue) request: \(userText)")
        }
    }

    private func userInputContent(
        text: String,
        attachments: [AgentAttachment],
        attachmentStore: AgentAttachmentStoring?
    ) -> LLMMessageContent {
        var parts: [LLMMessageContentPart] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(.text(trimmed))
        }

        for attachment in attachments {
            switch attachment.kind {
            case .image:
                guard let data = try? attachmentStore?.data(for: attachment) else {
                    parts.append(.text("[Attached image unavailable: \(attachment.fileName)]"))
                    continue
                }
                parts.append(.imageURL("data:\(attachment.mimeType);base64,\(data.base64EncodedString())"))
            case .textFile:
                guard let data = try? attachmentStore?.data(for: attachment),
                      let content = String(data: data, encoding: .utf8) else {
                    parts.append(.text("[Attached text file unavailable: \(attachment.fileName)]"))
                    continue
                }
                parts.append(.text(PromptText.join([
                    "Attached file: \(attachment.fileName)",
                    content,
                ])))
            }
        }

        guard !parts.isEmpty else { return .text("") }
        if parts.count == 1, case .text(let text) = parts[0] {
            return .text(text)
        }
        return .parts(parts)
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
                switch message.content {
                case .text(let text, _), .userInput(let text, _):
                    return text
                default:
                    return nil
                }
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
            partial + approximateTokenCount(message.content.plainText) + 4
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
