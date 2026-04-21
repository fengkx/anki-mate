import AnkiMateRPC
import Foundation

public struct AgentSummarizer {
    public struct Configuration: Sendable, Equatable {
        public var recentMessageLimit: Int
        public var batchSize: Int

        public init(
            recentMessageLimit: Int = 12,
            batchSize: Int = 5
        ) {
            self.recentMessageLimit = recentMessageLimit
            self.batchSize = batchSize
        }
    }

    public struct Batch: Sendable, Equatable {
        public let sourceMessages: [AgentChatMessage]

        public init(sourceMessages: [AgentChatMessage]) {
            self.sourceMessages = sourceMessages
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func nextBatch(from messages: [AgentChatMessage]) -> Batch? {
        let visible = messages
            .filter { $0.supersededBy == nil }
            .sorted { $0.ordinal < $1.ordinal }

        let older = visible.dropLast(min(configuration.recentMessageLimit, visible.count))
        let eligible = older.filter { message in
            guard message.status != .pending, message.status != .streaming else {
                return false
            }
            if case .summary = message.content {
                return false
            }
            return true
        }

        guard eligible.count >= configuration.batchSize else {
            return nil
        }

        return Batch(sourceMessages: Array(eligible.prefix(configuration.batchSize)))
    }

    public func buildPrompt(for batch: Batch) -> [LLMMessage] {
        let transcript = batch.sourceMessages.map { message in
            "[\(message.role.rawValue)#\(message.ordinal)] \(renderedContent(for: message.content))"
        }.joined(separator: "\n")

        return [
            LLMMessage(
                role: .system,
                content: [
                    "Summarize earlier agent-chat history for later context injection.",
                    "Preserve user intent, accepted or rejected directions, unresolved questions, and any concrete card-edit constraints.",
                    "Be concise, factual, and avoid inventing tool results or decisions."
                ].joined(separator: " ")
            ),
            LLMMessage(
                role: .user,
                content: [
                    "Summarize this earlier transcript into one compact paragraph.",
                    "Transcript:",
                    transcript
                ].joined(separator: "\n\n")
            )
        ]
    }

    private func renderedContent(for content: MessageContent) -> String {
        switch content {
        case .text(let text, _):
            return text
        case .toolCall(let name, let argsJSON):
            return "[Tool call] \(name) \(argsJSON)"
        case .toolResult(let name, let resultJSON, let truncated):
            return "[Tool result] \(name)\(truncated ? " (truncated)" : "") \(resultJSON)"
        case .actionProposal(let proposal):
            return "Proposal \(proposal.decision.rawValue): \(proposal.diffSummary)"
        case .summary(let text, _):
            return "Summary: \(text)"
        case .error(let message, let recoverable):
            return "Error (\(recoverable ? "recoverable" : "fatal")): \(message)"
        case .layoutRequestDeclined(let userText, let detectedKind):
            return "Declined \(detectedKind.rawValue): \(userText)"
        }
    }
}
