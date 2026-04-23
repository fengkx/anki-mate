import AnkiMateLLM
import DictKitAnkiExport
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

enum AgentComposerLayout {
    static let textContainerInset = NSSize(width: 8, height: 7)
    static let placeholderHorizontalPadding = textContainerInset.width
    static let placeholderVerticalPadding = textContainerInset.height
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

enum AgentComposerPasteboardImageReader {
    static func pngData(from pasteboard: NSPasteboard = .general) -> Data? {
        if let pngData = pasteboard.data(forType: .png) {
            return pngData
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let pngData = image.pngData() {
            return pngData
        }

        for url in imageFileURLs(from: pasteboard) {
            if let pngData = pngData(fromImageFileAt: url) {
                return pngData
            }
        }

        if let image = NSImage(pasteboard: pasteboard),
           let pngData = image.pngData() {
            return pngData
        }

        return nil
    }

    private static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []

        if !fileURLs.isEmpty {
            return fileURLs
        }

        let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] {
            return paths.map(URL.init(fileURLWithPath:))
        }

        guard let fileURLString = pasteboard.string(forType: .fileURL),
              let url = URL(string: fileURLString),
              url.isFileURL else {
            return []
        }
        return [url]
    }

    private static func pngData(fromImageFileAt url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .image) == true else {
            return nil
        }
        if type?.conforms(to: .png) == true,
           let data = try? Data(contentsOf: url),
           NSImage(data: data) != nil {
            return data
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        return image.pngData()
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
    let canSubmit: Bool
    let onPasteImage: () -> Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, hasMarkedText: $hasMarkedText, canSubmit: canSubmit, onSubmit: onSubmit)
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
        textView.textContainerInset = AgentComposerLayout.textContainerInset
        textView.textContainer?.lineFragmentPadding = 0
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
        textView.pasteImageHandler = onPasteImage
        textView.string = text
        textView.isEditable = !isDisabled
        context.coordinator.canSubmit = canSubmit
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
        textView.pasteImageHandler = onPasteImage
        context.coordinator.canSubmit = canSubmit
        context.coordinator.updateMarkedText(hasMarkedText)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var hasMarkedText: Bool
        var canSubmit: Bool
        private let onSubmit: () -> Void

        init(
            text: Binding<String>,
            hasMarkedText: Binding<Bool>,
            canSubmit: Bool,
            onSubmit: @escaping () -> Void
        ) {
            _text = text
            _hasMarkedText = hasMarkedText
            self.canSubmit = canSubmit
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
            guard canSubmit else { return }
            onSubmit()
        }
    }
}

final class AgentComposerTextView: NSTextView {
    var commandHandler: ((Selector, NSEvent?, Bool) -> Bool)?
    var markedTextHandler: ((Bool) -> Void)?
    var pasteImageHandler: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func doCommand(by selector: Selector) {
        if commandHandler?(selector, NSApp.currentEvent, hasMarkedText()) == true {
            return
        }
        super.doCommand(by: selector)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           pasteImageHandler?() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if pasteImageHandler?() == true {
            return
        }
        super.paste(sender)
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

private extension NSImage {
    func pngData() -> Data? {
        var rect = NSRect(origin: .zero, size: size)
        if let cgImage = cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            return bitmap.representation(using: .png, properties: [:])
        }

        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

struct AgentChatView: View {
    @ObservedObject var item: WordItem
    @ObservedObject var session: AgentSession
    let attachmentStore: AgentAttachmentFileStore
    let canAttachImages: Bool
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
    @State private var draftAttachments: [AgentAttachment] = []

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
                userBubble(message: row.message, text: text, attachments: [])
            } else {
                assistantBubble(message: row.message, text: text, reasoning: reasoning)
            }
        case .userInput(let text, let attachments):
            userBubble(message: row.message, text: text, attachments: attachments)
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

    private func userBubble(message: AgentChatMessage, text: String, attachments: [AgentAttachment]) -> some View {
        let isLastUser = message.id == lastUserMessageID

        return VStack(alignment: .trailing, spacing: 4) {
            Text(roleLabel(.user))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if editingMessageID == message.id {
                editField(message: message)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if !text.isEmpty {
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    attachmentList(attachments, allowRemoval: false)
                }
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

    @ViewBuilder
    private func attachmentList(_ attachments: [AgentAttachment], allowRemoval: Bool) -> some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(alignment: .top, spacing: 8) {
                        attachmentThumbnail(attachment)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.fileName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if let preview = attachment.extractedTextPreview, !preview.isEmpty {
                                Text(preview)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else {
                                Text("\(attachment.mimeType) · \(Self.formattedByteSize(attachment.byteSize))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if allowRemoval {
                            Button {
                                removeDraftAttachment(attachment)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(_ attachment: AgentAttachment) -> some View {
        if attachment.kind == .image,
           let image = NSImage(contentsOf: attachmentStore.url(for: attachment)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

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
        let attachments = attachments(for: message.content)
        return VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message…", text: $editText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)

            attachmentList(attachments, allowRemoval: false)

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
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
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
        case .text, .userInput, .error, .layoutRequestDeclined, .summary:
            return true
        case .toolCall, .toolResult, .actionProposal:
            return false
        }
    }

    // MARK: - Actions

    private func submitEdit() {
        let newText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let editingMessage = session.messages.first(where: { $0.id == editingMessageID }) else { return }
        guard !newText.isEmpty || !attachments(for: editingMessage.content).isEmpty else { return }
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
        guard !text.isEmpty || !draftAttachments.isEmpty else { return }
        guard !hasUnsupportedDraftImages else {
            errorMessage = "Image attachments require a fully downloaded vision model."
            return
        }
        let attachments = draftAttachments
        composerText = ""
        draftAttachments = []
        errorMessage = nil
        Task {
            do {
                try await session.sendUserMessage(text, attachments: attachments)
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
        VStack(alignment: .leading, spacing: 10) {
            if !draftAttachments.isEmpty {
                attachmentList(draftAttachments, allowRemoval: true)
            }

            ZStack(alignment: .topLeading) {
                if AgentComposerPlaceholderVisibility.shouldShow(
                    text: composerText,
                    hasMarkedText: composerHasMarkedText
                ) {
                    Text("Ask about the card or request a content edit…")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AgentComposerLayout.placeholderHorizontalPadding)
                        .padding(.vertical, AgentComposerLayout.placeholderVerticalPadding)
                        .allowsHitTesting(false)
                }

                AgentComposerInput(
                    text: $composerText,
                    hasMarkedText: $composerHasMarkedText,
                    isDisabled: session.isGenerating,
                    canSubmit: canSendDraft,
                    onPasteImage: pasteImageAttachment,
                    onSubmit: sendMessage
                )
            }
            .frame(height: composerInputHeight)

            HStack(alignment: .center, spacing: 10) {
                Button {
                    addAttachments()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(session.isGenerating)
                .help(canAttachImages ? "Attach images, Markdown, or text files" : "Attach Markdown or text files")

                if hasUnsupportedDraftImages {
                    Label("Image attachments require a fully downloaded vision model", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !canAttachImages {
                    Text("Text files only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(canSendDraft ? Color.white : Color.secondary)
                        .background(Circle().fill(canSendDraft ? Color.primary : Color.secondary.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(!canSendDraft)
                .help("Send")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.textBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(NSColor.separatorColor).opacity(0.8), lineWidth: 1)
        )
    }

    // MARK: - Rendering Helpers

    private func renderedContent(_ content: MessageContent) -> String {
        switch content {
        case .text(let text, _):
            return text
        case .userInput(let text, let attachments):
            let names = attachments.map(\.fileName).joined(separator: ", ")
            return names.isEmpty ? text : "\(text)\nAttachments: \(names)"
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

    private var hasUnsupportedDraftImages: Bool {
        !canAttachImages && draftAttachments.contains { $0.kind == .image }
    }

    private func attachments(for content: MessageContent) -> [AgentAttachment] {
        guard case .userInput(_, let attachments) = content else { return [] }
        return attachments
    }

    private var canSendDraft: Bool {
        !session.isGenerating &&
            !hasUnsupportedDraftImages &&
            (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty)
    }

    private var composerInputHeight: CGFloat {
        let explicitLines = max(1, composerText.split(separator: "\n", omittingEmptySubsequences: false).count)
        let clampedLines = min(explicitLines, 5)
        return 18 + CGFloat(clampedLines * 18)
    }

    private func addAttachments() {
        guard let sessionID = prepareSessionForAttachments() else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedAttachmentTypes

        guard panel.runModal() == .OK else { return }

        do {
            let imported = try attachmentStore.importFiles(
                panel.urls,
                sessionID: sessionID,
                existingCount: draftAttachments.count
            )
            draftAttachments.append(contentsOf: imported)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var allowedAttachmentTypes: [UTType] {
        var types: [UTType] = [
            .plainText,
            UTType(filenameExtension: "txt")!,
            UTType(filenameExtension: "md")!,
            UTType(filenameExtension: "markdown")!,
        ]
        if canAttachImages {
            types.append(.image)
        }
        return types
    }

    private func removeDraftAttachment(_ attachment: AgentAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
        try? attachmentStore.delete([attachment])
    }

    private func pasteImageAttachment() -> Bool {
        guard let pngData = AgentComposerPasteboardImageReader.pngData() else {
            return false
        }

        guard canAttachImages else {
            errorMessage = "Image attachments require a fully downloaded vision model."
            return true
        }

        guard !session.isGenerating, let sessionID = prepareSessionForAttachments() else {
            return true
        }

        do {
            let attachment = try attachmentStore.importPastedImage(
                pngData,
                sessionID: sessionID,
                existingCount: draftAttachments.count
            )
            draftAttachments.append(attachment)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }

    private func prepareSessionForAttachments() -> UUID? {
        if session.sessionRecord == nil {
            do {
                try session.reload()
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
        guard let sessionID = session.sessionRecord?.id else {
            errorMessage = "Chat session is not ready."
            return nil
        }
        return sessionID
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

    private static func formattedByteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
