import AnkiMateLLM
import DictKitAnkiExport
import SwiftUI

struct AgentChatView: View {
    @ObservedObject var item: WordItem
    @ObservedObject var session: AgentSession
    @Binding var previewOverrideArtifacts: AIArtifacts?

    @State private var composerText = ""
    @State private var errorMessage: String?
    @State private var previewingProposalID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            contextBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(session.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.count) { _ in
                    if let lastID = session.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            composer
        }
        .task(id: item.id) {
            do {
                try session.reload()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onReceive(session.$previewOverrideArtifacts) { value in
            previewOverrideArtifacts = value
            if value == nil {
                previewingProposalID = nil
            }
        }
    }

    private var contextBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Label(item.word, systemImage: "bubble.left.and.bubble.right")
                .font(.subheadline.weight(.semibold))

            Text(item.lookupResult == nil ? "lookup pending" : "snapshot ready")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !session.pendingProposals.isEmpty {
                Text("\(session.pendingProposals.count) pending")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("Clear Chat") {
                do {
                    try session.clearChat()
                    previewingProposalID = nil
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(session.isGenerating || session.messages.isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask the Agent to inspect the current card, explain a usage distinction, or propose a content edit.")
                .font(.subheadline)
            Text("Content edits become pending proposals before anything is applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
    }

    @ViewBuilder
    private func messageRow(_ message: AgentChatMessage) -> some View {
        switch message.content {
        case .text(let text):
            bubble(text: text, role: message.role)
        case .error(let text, _):
            bubble(text: text, role: .assistant, tint: .red.opacity(0.12))
        case .layoutRequestDeclined(_, _):
            bubble(text: renderedContent(message.content), role: .assistant, tint: .orange.opacity(0.12))
        case .toolCall, .toolResult:
            toolTraceRow(message)
        case .actionProposal(let proposal):
            proposalCard(messageID: message.id, proposal: proposal)
        case .summary:
            bubble(text: renderedContent(message.content), role: .assistant, tint: .secondary.opacity(0.08))
        }
    }

    private func bubble(
        text: String,
        role: AgentChatMessage.Role,
        tint: Color? = nil
    ) -> some View {
        VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
            Text(roleLabel(role))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(
                        tint ?? (role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                    )
                )
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
    }

    private func toolTraceRow(_ message: AgentChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .tool ? "Tool Result" : "Tool Call")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(renderedContent(message.content))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func proposalCard(messageID: UUID, proposal: ProposalRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(proposalTitle(proposal))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(proposal.decision.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(proposalStatusColor(proposal.decision))
            }

            Text(proposal.diffSummary)
                .font(.body)
                .textSelection(.enabled)

            if let rationale = proposal.rationale, !rationale.isEmpty {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button(previewingProposalID == proposal.id ? "Hide Preview" : "Preview") {
                    do {
                        if previewingProposalID == proposal.id {
                            session.clearPreviewOverride()
                        } else {
                            try session.previewProposal(proposal.id)
                            previewingProposalID = proposal.id
                        }
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(proposal.decision != .pending)

                Button("Apply") {
                    do {
                        try session.applyProposal(proposal.id)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(proposal.decision != .pending)

                Button("Dismiss") {
                    do {
                        try session.dismissProposal(proposal.id)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(proposal.decision != .pending)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.18), lineWidth: 1))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about the card or request a content edit…", text: $composerText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(session.isGenerating)

            if session.isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            }

            Button("Send") {
                sendMessage()
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isGenerating || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sendMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        errorMessage = nil
        Task {
            do {
                try await session.sendUserMessage(text)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func renderedContent(_ content: MessageContent) -> String {
        switch content {
        case .text(let text):
            return text
        case .toolCall(let name, let argsJSON):
            return "\(name)\n\(argsJSON)"
        case .toolResult(let name, let resultJSON, let truncated):
            return "\(name)\(truncated ? " (truncated)" : "")\n\(resultJSON)"
        case .actionProposal(let proposal):
            return proposal.diffSummary
        case .summary(let text, _):
            return text
        case .error(let message, _):
            return message
        case .layoutRequestDeclined(let userText, let detectedKind):
            return "Declined \(detectedKind.rawValue) request: \(userText)"
        }
    }

    private func roleLabel(_ role: AgentChatMessage.Role) -> String {
        switch role {
        case .user:
            return "You"
        case .assistant:
            return "Agent"
        case .tool:
            return "Tool"
        case .system:
            return "System"
        }
    }

    private func proposalTitle(_ proposal: ProposalRecord) -> String {
        let kind: String = switch proposal.kind {
        case .usageCue:
            "Usage Cue"
        case .example:
            "Example"
        case .recallDraft:
            "Recall Draft"
        case .pitfall:
            "Pitfall"
        case .mnemonic:
            "Mnemonic"
        case .collocation:
            "Collocation"
        case .deleteAccepted:
            "Delete Accepted"
        }
        return "\(kind) Proposal"
    }

    private func proposalStatusColor(_ decision: ProposalRecord.Decision) -> Color {
        switch decision {
        case .pending:
            return .orange
        case .applied:
            return .green
        case .dismissed:
            return .secondary
        }
    }
}
