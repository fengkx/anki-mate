import AnkiMateLLM
import DictKitAnkiExport
import AppKit
import SwiftUI

enum AgentComposerInputCommand: Equatable {
    case submit
    case insertNewline
    case passthrough
}

enum AgentComposerPlaceholderVisibility {
    static func shouldShow(text: String, hasMarkedText: Bool) -> Bool {
        text.isEmpty && !hasMarkedText
    }
}

enum AgentComposerTextSync {
    static func shouldApplyBoundText(
        currentText: String,
        boundText: String,
        hasMarkedText: Bool
    ) -> Bool {
        !hasMarkedText && currentText != boundText
    }
}

enum AgentComposerInputCommandResolver {
    static func command(
        for selector: Selector,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> AgentComposerInputCommand {
        guard selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else {
            return .passthrough
        }

        guard !hasMarkedText else {
            return .passthrough
        }

        if modifierFlags.contains(.command) {
            return .insertNewline
        }

        return .submit
    }
}

struct AgentComposerInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var hasMarkedText: Bool
    let isDisabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, hasMarkedText: $hasMarkedText, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView: AgentComposerTextView
        if let existing = scrollView.documentView as? AgentComposerTextView {
            textView = existing
        } else if let existing = scrollView.documentView as? NSTextView,
                  let textContainer = existing.textContainer,
                  let textStorage = existing.textStorage {
            let replacement = AgentComposerTextView(frame: existing.frame, textContainer: textContainer)
            replacement.layoutManager?.replaceTextStorage(textStorage)
            replacement.delegate = context.coordinator
            scrollView.documentView = replacement
            textView = replacement
        } else {
            textView = AgentComposerTextView()
            scrollView.documentView = textView
        }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.commandHandler = { selector, event, hasMarkedText in
            switch AgentComposerInputCommandResolver.command(
                for: selector,
                modifierFlags: event?.modifierFlags ?? [],
                hasMarkedText: hasMarkedText
            ) {
            case .submit:
                context.coordinator.submitIfPossible()
                return true
            case .insertNewline:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .passthrough:
                return false
            }
        }
        textView.markedTextHandler = { hasMarkedText in
            context.coordinator.updateMarkedText(hasMarkedText)
        }
        textView.string = text
        textView.isEditable = !isDisabled
        context.coordinator.updateMarkedText(textView.hasMarkedText())
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? AgentComposerTextView else { return }
        let hasMarkedText = textView.hasMarkedText()
        if AgentComposerTextSync.shouldApplyBoundText(
            currentText: textView.string,
            boundText: text,
            hasMarkedText: hasMarkedText
        ) {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        context.coordinator.updateMarkedText(hasMarkedText)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var hasMarkedText: Bool
        private let onSubmit: () -> Void

        init(
            text: Binding<String>,
            hasMarkedText: Binding<Bool>,
            onSubmit: @escaping () -> Void
        ) {
            _text = text
            _hasMarkedText = hasMarkedText
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            hasMarkedText = textView.hasMarkedText()
        }

        func updateMarkedText(_ value: Bool) {
            guard hasMarkedText != value else { return }
            hasMarkedText = value
        }

        func submitIfPossible() {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            onSubmit()
        }
    }
}

final class AgentComposerTextView: NSTextView {
    var commandHandler: ((Selector, NSEvent?, Bool) -> Bool)?
    var markedTextHandler: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func doCommand(by selector: Selector) {
        if commandHandler?(selector, NSApp.currentEvent, hasMarkedText()) == true {
            return
        }
        super.doCommand(by: selector)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextHandler?(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextHandler?(hasMarkedText())
    }
}

struct AgentChatView: View {
    @ObservedObject var item: WordItem
    @ObservedObject var session: AgentSession
    @Binding var previewOverrideArtifacts: AIArtifacts?

    @State private var composerText = ""
    @State private var composerHasMarkedText = false
    @State private var errorMessage: String?
    @State private var previewingProposalID: UUID?
    @State private var editingMessageID: UUID?
    @State private var editText = ""
    @State private var hoveredMessageID: UUID?
    @State private var showThinkingForMessage: UUID?
    @State private var thinkingExpanded = true
    @State private var thinkingStartTime: Date?
    @State private var thinkingElapsedRefresh = Date()
    @State private var expandedThinkingMessages: Set<UUID> = []

    private var reloadTaskKey: String {
        "\(item.id.uuidString)-\(ObjectIdentifier(session))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            contextBar

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.messages.isEmpty && !session.isGenerating {
                            emptyState
                        } else {
                            ForEach(AgentChatDisplayComposer.compose(session.messages)) { row in
                                messageRow(row)
                                    .id(row.id)
                            }

                            // Streaming indicator or typing dots
                            if session.isGenerating {
                                streamingOrTypingIndicator
                                    .id("streaming-indicator")
                            }
                        }
                    }
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.messages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.streamingText) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.streamingReasoning) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.isGenerating) { generating in
                    if generating {
                        scrollToBottom(proxy)
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
        .task(id: reloadTaskKey) {
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

    // MARK: - Context Bar

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

    // MARK: - Empty State

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

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ row: AgentChatDisplayRow) -> some View {
        switch row.message.content {
        case .text(let text, let reasoning):
            if row.message.role == .user {
                userBubble(message: row.message, text: text)
            } else {
                assistantBubble(message: row.message, text: text, reasoning: reasoning)
            }
        case .error(let text, _):
            assistantBubble(message: row.message, text: text, tint: .red.opacity(0.12))
        case .layoutRequestDeclined(_, _):
            assistantBubble(message: row.message, text: renderedContent(row.message.content), tint: .orange.opacity(0.12))
        case .toolCall, .toolResult:
            toolTraceRow(row.message)
        case .actionProposal(let proposal):
            proposalCard(
                messageID: row.message.id,
                proposal: proposal,
                sourceToolCall: row.embeddedToolCall
            )
        case .summary:
            assistantBubble(
                message: row.message,
                text: renderedContent(row.message.content),
                tint: .secondary.opacity(0.08)
            )
        }
    }

    // MARK: - User Bubble

    private func userBubble(message: AgentChatMessage, text: String) -> some View {
        let isLastUser = message.id == lastUserMessageID

        return VStack(alignment: .trailing, spacing: 4) {
            Text(roleLabel(.user))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if editingMessageID == message.id {
                editField(message: message)
            } else {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.12))
                    )
            }

            // Action buttons
            if !session.isGenerating && editingMessageID == nil {
                HStack(spacing: 6) {
                    copyButton(text: text)
                    if isLastUser {
                        editButton(message: message, text: text)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant Bubble

    private func assistantBubble(
        message: AgentChatMessage,
        text: String,
        reasoning: String? = nil,
        tint: Color? = nil
    ) -> some View {
        let isLastAssistant = message.id == lastAssistantMessageID

        return VStack(alignment: .leading, spacing: 4) {
            Text(roleLabel(.assistant))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                // Persisted reasoning (collapsible)
                if let reasoning, !reasoning.isEmpty {
                    persistedThinkingSection(messageID: message.id, text: reasoning)
                }

                // Content
                markdownText(text)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint ?? Color.secondary.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Action buttons
            if !session.isGenerating && editingMessageID == nil {
                HStack(spacing: 6) {
                    copyButton(text: text)
                    if isLastAssistant {
                        regenerateButton
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Thinking section for persisted messages — collapsed by default, user-toggleable.
    @ViewBuilder
    private func persistedThinkingSection(messageID: UUID, text: String) -> some View {
        let isExpanded = expandedThinkingMessages.contains(messageID)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedThinkingMessages.remove(messageID)
                    } else {
                        expandedThinkingMessages.insert(messageID)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text("Thought process")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Streaming / Typing Indicator

    @ViewBuilder
    private var streamingOrTypingIndicator: some View {
        let hasReasoning = !session.streamingReasoning.isEmpty
        let hasContent = !session.streamingText.isEmpty
        let isThinking = hasReasoning && !hasContent

        VStack(alignment: .leading, spacing: 4) {
            Text(roleLabel(.assistant))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                // Thinking section
                if hasReasoning {
                    streamingThinkingSection(isThinking: isThinking)
                }

                // Content section
                if hasContent {
                    markdownText(session.streamingText)
                        .textSelection(.enabled)
                        .padding(12)
                } else if !hasReasoning {
                    typingDots
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: session.streamingReasoning) { reasoning in
            // Start tracking thinking time on first reasoning delta
            if !reasoning.isEmpty && thinkingStartTime == nil {
                let now = Date()
                thinkingStartTime = now
                thinkingElapsedRefresh = now
                thinkingExpanded = true
            }
        }
        .onChange(of: session.streamingText) { content in
            // Auto-collapse thinking when real content arrives
            if !content.isEmpty && thinkingExpanded {
                withAnimation(.easeInOut(duration: 0.2)) {
                    thinkingExpanded = false
                }
            }
        }
        .onChange(of: session.isGenerating) { generating in
            if generating {
                // Reset for new generation
                thinkingExpanded = true
                thinkingStartTime = nil
                thinkingElapsedRefresh = Date()
            }
        }
        .task(id: thinkingStartTime) {
            guard thinkingStartTime != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                thinkingElapsedRefresh = Date()
            }
        }
    }

    @ViewBuilder
    private func streamingThinkingSection(isThinking: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (always visible, toggles collapse)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    thinkingExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)

                    Image(systemName: "brain")
                        .font(.caption2)

                    if isThinking {
                        Text("Thinking...")
                            .font(.caption2.weight(.medium))
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        let elapsed = thinkingElapsedText
                        Text("Thought\(elapsed)")
                            .font(.caption2.weight(.medium))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Collapsible body
            if thinkingExpanded {
                Divider()
                    .padding(.horizontal, 12)

                Text(session.streamingReasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    private var thinkingElapsedText: String {
        guard let start = thinkingStartTime else { return "" }
        let seconds = Int(thinkingElapsedRefresh.timeIntervalSince(start))
        if seconds < 1 { return "" }
        return " for \(seconds)s"
    }

    private var typingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                        value: session.isGenerating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Markdown Helper

    @ViewBuilder
    private func markdownText(_ text: String) -> some View {
        let lines = AgentMarkdownRenderer.renderLines(text)

        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isBlank {
                    Color.clear
                        .frame(height: 8)
                } else {
                    Text(line.content)
                        .font(line.isCode ? .system(.body, design: .monospaced) : .body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if session.isGenerating {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo("streaming-indicator", anchor: .bottom)
            }
        } else if let lastID = session.messages.last?.id {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    // MARK: - Action Buttons

    private func copyButton(text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Copy")
    }

    private func editButton(message: AgentChatMessage, text: String) -> some View {
        Button {
            editText = text
            editingMessageID = message.id
        } label: {
            Image(systemName: "pencil")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Edit")
    }

    private var regenerateButton: some View {
        Button {
            regenerateLastResponse()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Regenerate")
    }

    // MARK: - Edit Field

    private func editField(message: AgentChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message…", text: $editText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)

            HStack(spacing: 6) {
                Button("Cancel") {
                    editingMessageID = nil
                    editText = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Send") {
                    submitEdit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06)))
    }

    // MARK: - Computed Helpers

    private var lastUserMessageID: UUID? {
        session.messages.last(where: { $0.role == .user })?.id
    }

    private var lastAssistantMessageID: UUID? {
        session.messages.last(where: {
            $0.role == .assistant && isVisibleContent($0.content)
        })?.id
    }

    private func isVisibleContent(_ content: MessageContent) -> Bool {
        switch content {
        case .text, .error, .layoutRequestDeclined, .summary:
            return true
        case .toolCall, .toolResult, .actionProposal:
            return false
        }
    }

    // MARK: - Actions

    private func submitEdit() {
        let newText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }
        editingMessageID = nil
        editText = ""
        errorMessage = nil
        Task {
            do {
                try await session.editLastUserMessage(newText)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func regenerateLastResponse() {
        errorMessage = nil
        Task {
            do {
                try await session.regenerateLastResponse()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
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

    // MARK: - Tool Trace

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

    // MARK: - Proposal Card

    private func proposalCard(
        messageID: UUID,
        proposal: ProposalRecord,
        sourceToolCall: AgentChatDisplayRow.EmbeddedToolCall?
    ) -> some View {
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

            if let sourceToolCall {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tool Call")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("\(sourceToolCall.name)\n\(sourceToolCall.argsJSON)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }
            }

            if proposal.decision == .pending {
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
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.18), lineWidth: 1))
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if AgentComposerPlaceholderVisibility.shouldShow(
                    text: composerText,
                    hasMarkedText: composerHasMarkedText
                ) {
                    Text("Ask about the card or request a content edit…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }

                AgentComposerInput(
                    text: $composerText,
                    hasMarkedText: $composerHasMarkedText,
                    isDisabled: session.isGenerating,
                    onSubmit: sendMessage
                )
            }
            .frame(minHeight: 40, maxHeight: 96)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor))
            )

            Button("Send") {
                sendMessage()
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isGenerating || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Rendering Helpers

    private func renderedContent(_ content: MessageContent) -> String {
        switch content {
        case .text(let text, _):
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
