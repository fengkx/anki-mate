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
            - The XML card context is the source of truth for visible content, editable ids, source-only ids, and related card variants.
            - Use replace/delete only for XML nodes marked editable="true"; their id attribute is the targetID.
            - Use source-only XML nodes as evidence or anchors, not as targetID values.
            - First infer the learner's immediate task from the user's request and the card context.
            - Prefer the information that most directly helps the learner succeed at that immediate task.
            - When the learner is trying to distinguish, recall, choose, fill, or avoid an error, give discriminative help instead of broad background explanation.
            - Do not drift into adjacent knowledge unless it clearly improves success on the learner's immediate task.
            - If the user asks for help solving, understanding, or remembering visible content, answer in chat unless they also ask to change card content.
            - When writing a mnemonic, consider sound, imagery, spelling, contrast, and plausible word structure. Use prefixes, roots, suffixes, or meaningful chunks when they make a compact memory hook, but do not invent fake etymology.
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
            - operation=replace and operation=delete must include targetID from an editable="true" XML node.
            - If one user request needs multiple card changes, use multiple proposal tool calls instead of merging the changes into one invalid replace/delete.
            - When adding an example without exact text, generate a useful example for the current headword yourself and propose it.
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
            PromptText.labeledBlock("Card XML", value: cardSnapshotXML(snapshot, source: "current")),
            relatedSnapshotsText(relatedSnapshots),
            pendingSummary.map { PromptText.labeledBlock("Pending proposals", value: $0) },
            decisionSummary.map { PromptText.labeledBlock("Recent proposal decisions", value: $0) }
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

    private func cardSnapshotXML(_ snapshot: CardRenderSnapshot, source: String) -> String {
        guard let object = structuredJSONObject(from: snapshot.structuredJSON) else {
            return PromptText.join([
                #"<card_snapshot source="\#(xmlAttribute(source))" kind="\#(xmlAttribute(snapshot.kind.rawValue))" word="\#(xmlAttribute(snapshot.word))">"#,
                xmlElement("pronunciation", snapshot.phonetic, indent: "  "),
                "</card_snapshot>"
            ])
        }

        let kind = stringValue("kind", in: object) ?? snapshot.kind.rawValue
        var lines: [String] = [
            #"<card_snapshot source="\#(xmlAttribute(source))" kind="\#(xmlAttribute(kind))" word="\#(xmlAttribute(snapshot.word))">"#
        ]
        if !snapshot.phonetic.isEmpty {
            lines.append(xmlElement("pronunciation", snapshot.phonetic, indent: "  "))
        }

        if kind == CardRenderSnapshot.Kind.recall.rawValue {
            lines.append(contentsOf: recallXML(from: object))
        } else {
            lines.append(contentsOf: standardXML(from: object))
        }

        lines.append("</card_snapshot>")
        return lines.joined(separator: "\n")
    }

    private func standardXML(from object: [String: Any]) -> [String] {
        var lines: [String] = []
        let senses = arrayOfObjects("senses", in: object)
        if !senses.isEmpty {
            lines.append("  <dictionary>")
            for sense in senses {
                let senseID = stringValue("id", in: sense) ?? "sense"
                let pos = stringValue("pos", in: sense) ?? ""
                lines.append(#"    <sense id="\#(xmlAttribute(senseID))" editable="false" part_of_speech="\#(xmlAttribute(pos))">"#)
                if let definition = stringValue("definition", in: sense) {
                    lines.append(xmlElement("definition", definition, indent: "      "))
                }
                for (index, example) in arrayOfStrings("examples", in: sense).enumerated() {
                    let sourceID = "\(senseID):example-\(index)"
                    lines.append(xmlElement(
                        "dictionary_example",
                        example,
                        attributes: [
                            ("source_id", sourceID),
                            ("editable", "false"),
                        ],
                        indent: "      "
                    ))
                }
                lines.append("    </sense>")
            }
            lines.append("  </dictionary>")
        }

        if let artifacts = object["artifacts"] as? [String: Any] {
            lines.append(contentsOf: acceptedArtifactsXML(from: artifacts))
        }
        return lines
    }

    private func recallXML(from object: [String: Any]) -> [String] {
        var lines: [String] = []
        if let recall = object["recall"] as? [String: Any] {
            let mode = stringValue("mode", in: recall)
            let front = stringValue("front", in: recall)
            let back = stringValue("back", in: recall)
            let maskedToken = front.flatMap { extractMaskedToken(in: $0, expectedLength: back?.count) }
            let hiddenSegment = maskedToken.flatMap { token in
                back.flatMap { deriveHiddenSegment(maskedToken: token, answer: $0) }
            }

            lines.append(#"  <recall id="recall-draft" editable="true">"#)
            if let mode {
                lines.append(xmlElement("mode", mode, indent: "    "))
            }
            if let front {
                lines.append(xmlElement(
                    "front",
                    front,
                    attributes: [
                        ("masked_token", maskedToken),
                        ("hidden_segment", hiddenSegment),
                    ],
                    indent: "    "
                ))
            }
            if let back {
                lines.append(xmlElement("back", back, indent: "    "))
            }
            if let hint = stringValue("hint", in: recall) {
                lines.append(xmlElement("hint", hint, indent: "    "))
            }
            lines.append("  </recall>")
        } else {
            lines.append(#"  <recall id="recall-draft" editable="false" />"#)
        }

        let references = arrayOfObjects("reference", in: object)
        if !references.isEmpty {
            lines.append("  <reference>")
            for reference in references {
                let senseID = stringValue("id", in: reference) ?? "sense"
                let pos = stringValue("pos", in: reference) ?? ""
                lines.append(#"    <sense id="\#(xmlAttribute(senseID))" editable="false" part_of_speech="\#(xmlAttribute(pos))">"#)
                if let definition = stringValue("definition", in: reference) {
                    lines.append(xmlElement("definition", definition, indent: "      "))
                }
                lines.append("    </sense>")
            }
            lines.append("  </reference>")
        }
        return lines
    }

    private func acceptedArtifactsXML(from artifacts: [String: Any]) -> [String] {
        var lines: [String] = ["  <accepted_artifacts>"]
        if let usageCue = artifacts["usageCue"] as? [String: Any],
           let text = stringValue("text", in: usageCue) {
            lines.append(xmlElement(
                "usage_cue",
                text,
                attributes: [("id", "usage-cue"), ("editable", "true")],
                indent: "    "
            ))
        }
        appendArtifactCollection(
            tag: "examples",
            itemTag: "example",
            items: arrayOfObjects("examples", in: artifacts),
            textKeys: ["text", "translation", "note"],
            lines: &lines
        )
        appendArtifactCollection(
            tag: "pitfalls",
            itemTag: "pitfall",
            items: arrayOfObjects("pitfalls", in: artifacts),
            textKeys: ["text", "translation", "category"],
            lines: &lines
        )
        appendArtifactCollection(
            tag: "mnemonics",
            itemTag: "mnemonic",
            items: arrayOfObjects("mnemonics", in: artifacts),
            textKeys: ["text", "translation", "kind"],
            lines: &lines
        )
        appendArtifactCollection(
            tag: "collocations",
            itemTag: "collocation",
            items: arrayOfObjects("collocations", in: artifacts),
            textKeys: ["phrase", "note"],
            lines: &lines
        )
        lines.append("  </accepted_artifacts>")
        return lines
    }

    private func appendArtifactCollection(
        tag: String,
        itemTag: String,
        items: [[String: Any]],
        textKeys: [String],
        lines: inout [String]
    ) {
        guard !items.isEmpty else { return }
        lines.append("    <\(tag)>")
        for item in items {
            let id = stringValue("id", in: item) ?? itemTag
            lines.append(#"      <\#(itemTag) id="\#(xmlAttribute(id))" editable="true">"#)
            for key in textKeys {
                if let value = stringValue(key, in: item), !value.isEmpty {
                    lines.append(xmlElement(key, value, indent: "        "))
                }
            }
            lines.append("      </\(itemTag)>")
        }
        lines.append("    </\(tag)>")
    }

    private func stringValue(_ key: String, in object: [String: Any]) -> String? {
        guard let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func arrayOfObjects(_ key: String, in object: [String: Any]) -> [[String: Any]] {
        object[key] as? [[String: Any]] ?? []
    }

    private func arrayOfStrings(_ key: String, in object: [String: Any]) -> [String] {
        object[key] as? [String] ?? []
    }

    private func xmlElement(
        _ name: String,
        _ text: String,
        attributes: [(String, String?)] = [],
        indent: String
    ) -> String {
        let renderedAttributes = attributes.compactMap { key, value -> String? in
            guard let value else { return nil }
            return #"\#(key)="\#(xmlAttribute(value))""#
        }.joined(separator: " ")
        let suffix = renderedAttributes.isEmpty ? "" : " \(renderedAttributes)"
        return "\(indent)<\(name)\(suffix)>\(xmlText(text))</\(name)>"
    }

    private func xmlAttribute(_ value: String) -> String {
        xmlText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func xmlText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
        let rendered = snapshots.enumerated().map { index, snapshot in
            PromptText.join([
                "Snapshot kind: \(snapshot.kind.rawValue)",
                PromptText.labeledBlock(
                    "Card XML",
                    value: cardSnapshotXML(snapshot, source: "related-\(index + 1)")
                )
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
