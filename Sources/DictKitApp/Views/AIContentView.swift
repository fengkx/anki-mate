import SwiftUI
import DictKit
import AnkiMateLLM
import os

struct AIContentView: View {
    @ObservedObject var item: WordItem
    @EnvironmentObject private var llmService: LLMService
    @EnvironmentObject private var viewModel: WordListViewModel

    @State private var examplesErrorMessage: String?
    @State private var usageErrorMessage: String?
    @State private var editingSuggestedDefinition = ""
    @State private var editingAcceptedDefinition = ""
    @State private var streamingExamplesText = ""
    @State private var streamingUsageText = ""
    @State private var suggestedExampleDrafts: [Int: String] = [:]
    @State private var acceptedExampleDrafts: [Int: String] = [:]
    @State private var examplesTask: Task<Void, Never>?
    @State private var usageTask: Task<Void, Never>?
    @State private var acceptedDefinitionAutosaveTask: Task<Void, Never>?
    @State private var acceptedExampleAutosaveTasks: [Int: Task<Void, Never>] = [:]

    private let logger = Logger(subsystem: "AnkiMateApp", category: "AIContentView")

    private var isGeneratingExamples: Bool {
        examplesTask != nil
    }

    private var isGeneratingUsage: Bool {
        usageTask != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Assistant", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    if isGeneratingExamples {
                        generationBadge("Examples")
                    }
                    if isGeneratingUsage {
                        generationBadge("Usage")
                    }
                }
            }

            if !llmService.hasModel {
                noModelView
            } else {
                actionButtons

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionCard {
                            sentencesSection
                        }

                        sectionCard {
                            definitionNoteSection
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.quaternary.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
        .onAppear {
            syncExampleDrafts()
            editingSuggestedDefinition = item.aiSuggestedDefinitionNote ?? ""
            editingAcceptedDefinition = item.aiAcceptedDefinitionNote ?? ""
            syncGeneratingState()
        }
        .onChange(of: item.aiSuggestedExampleSentences) { _ in
            syncExampleDrafts()
        }
        .onChange(of: item.aiAcceptedExampleSentences) { _ in
            syncExampleDrafts()
        }
        .onChange(of: item.aiSuggestedDefinitionNote) { newValue in
            editingSuggestedDefinition = newValue ?? ""
        }
        .onChange(of: item.aiAcceptedDefinitionNote) { newValue in
            editingAcceptedDefinition = newValue ?? ""
        }
        .onDisappear {
            examplesTask?.cancel()
            usageTask?.cancel()
            acceptedDefinitionAutosaveTask?.cancel()
            acceptedExampleAutosaveTasks.values.forEach { $0.cancel() }
            examplesTask = nil
            usageTask = nil
            acceptedDefinitionAutosaveTask = nil
            acceptedExampleAutosaveTasks = [:]
            syncGeneratingState()
        }
    }

    // MARK: - No Model

    @ViewBuilder
    private var noModelView: some View {
        Text("Download and select a model in AI settings to enable AI features.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                generateSentences()
            } label: {
                actionButtonLabel(
                    title: isGeneratingExamples ? "Generating Examples..." : "Regenerate Examples",
                    systemImage: "text.quote",
                    isLoading: isGeneratingExamples
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isGeneratingExamples || !llmService.hasModel)

            Button {
                optimizeDefinition()
            } label: {
                actionButtonLabel(
                    title: isGeneratingUsage ? "Generating Usage..." : "Regenerate Usage Hint",
                    systemImage: "text.magnifyingglass",
                    isLoading: isGeneratingUsage
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isGeneratingUsage || !llmService.hasModel || firstDefinition == nil)
        }
    }

    @ViewBuilder
    private func actionButtonLabel(title: String, systemImage: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.subheadline)
    }

    // MARK: - Sentences Section

    @ViewBuilder
    private var sentencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Examples")

            if !item.aiSuggestedExampleSentences.isEmpty {
                sectionSubheader("Suggested")
                ForEach(Array(item.aiSuggestedExampleSentences.indices), id: \.self) { index in
                    EditableAITextCard(
                        text: bindingForSuggestedExample(at: index),
                        primaryButtonTitle: "Accept",
                        secondaryButtonTitle: "Reject",
                        onPrimary: { acceptSuggestedExample(at: index) },
                        onSecondary: { rejectSuggestedExample(at: index) }
                    )
                }
            } else if isGeneratingExamples && !streamingExamplesText.isEmpty {
                sectionSubheader("Streaming")
                streamingCard(streamingExamplesText)
            } else {
                emptyState("No suggestions yet.")
            }

            if let examplesErrorMessage {
                errorLabel(examplesErrorMessage)
            }

            if !item.aiAcceptedExampleSentences.isEmpty {
                sectionSubheader("Accepted")
                    .padding(.top, 2)
                ForEach(Array(item.aiAcceptedExampleSentences.indices), id: \.self) { index in
                    EditableAITextCard(
                        text: bindingForAcceptedExample(at: index),
                        secondaryButtonTitle: "Delete",
                        tagText: "AI-generated",
                        onTextChange: { scheduleAcceptedExampleAutosave(at: index, value: $0) },
                        onSecondary: { deleteAcceptedExample(at: index) }
                    )
                }
            }
        }
    }

    // MARK: - Definition Note Section

    @ViewBuilder
    private var definitionNoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Usage")

            if item.aiSuggestedDefinitionNote != nil {
                sectionSubheader("Suggested")
                EditableAITextCard(
                    text: $editingSuggestedDefinition,
                    primaryButtonTitle: "Accept",
                    secondaryButtonTitle: "Reject",
                    onPrimary: acceptSuggestedDefinition,
                    onSecondary: rejectSuggestedDefinition
                )
            } else if isGeneratingUsage && !streamingUsageText.isEmpty {
                sectionSubheader("Streaming")
                streamingCard(streamingUsageText)
            } else {
                emptyState("No suggestion yet.")
            }

            if let usageErrorMessage {
                errorLabel(usageErrorMessage)
            }

            if item.aiAcceptedDefinitionNote != nil {
                sectionSubheader("Accepted")
                    .padding(.top, 2)
                EditableAITextCard(
                    text: $editingAcceptedDefinition,
                    secondaryButtonTitle: "Delete",
                    tagText: "AI-generated",
                    onTextChange: scheduleAcceptedDefinitionAutosave,
                    onSecondary: deleteAcceptedDefinition
                )
            }
        }
    }

    // MARK: - Actions

    private func generateSentences() {
        guard examplesTask == nil else { return }
        guard let result = item.lookupResult else { return }
        let senses = sensePromptInputs(from: result)
        guard !senses.isEmpty else { return }

        examplesErrorMessage = nil
        streamingExamplesText = ""
        logger.info("Regenerate Examples started for \(item.word, privacy: .public)")

        examplesTask?.cancel()
        examplesTask = Task { @MainActor in
            syncGeneratingState()
            defer {
                examplesTask = nil
                streamingExamplesText = ""
                syncGeneratingState()
            }

            do {
                let sentences = try await llmService.generateExampleSentencesStreaming(
                    word: item.word,
                    senses: senses,
                    onDelta: { delta in
                        Task { @MainActor in
                            streamingExamplesText += delta
                        }
                    }
                )
                viewModel.saveAISuggestedExampleSentences(sentences, for: item)
                logger.info("Regenerate Examples finished, \(sentences.count) lines")
            } catch {
                examplesErrorMessage = error.localizedDescription
                logger.error("Regenerate Examples failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func optimizeDefinition() {
        guard usageTask == nil else { return }
        guard let result = item.lookupResult else { return }
        let senses = sensePromptInputs(from: result)
        guard !senses.isEmpty else { return }

        usageErrorMessage = nil
        streamingUsageText = ""
        logger.info("Regenerate Usage started for \(item.word, privacy: .public)")

        usageTask?.cancel()
        usageTask = Task { @MainActor in
            syncGeneratingState()
            defer {
                usageTask = nil
                streamingUsageText = ""
                syncGeneratingState()
            }

            do {
                let optimized = try await llmService.optimizeDefinitionStreaming(
                    word: item.word,
                    senses: senses,
                    onDelta: { delta in
                        Task { @MainActor in
                            streamingUsageText += delta
                        }
                    }
                )
                viewModel.saveAISuggestedDefinitionNote(optimized, for: item)
                editingSuggestedDefinition = optimized
                logger.info("Regenerate Usage finished")
            } catch {
                usageErrorMessage = error.localizedDescription
                logger.error("Regenerate Usage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func acceptSuggestedExample(at index: Int) {
        guard let suggested = item.aiSuggestedExampleSentences[safe: index] else { return }
        let trimmed = (suggestedExampleDrafts[index] ?? suggested).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var accepted = item.aiAcceptedExampleSentences
        accepted.append(trimmed)
        viewModel.saveAIAcceptedExampleSentences(accepted, for: item)

        var remaining = item.aiSuggestedExampleSentences
        remaining.remove(at: index)
        viewModel.saveAISuggestedExampleSentences(remaining, for: item)
    }

    private func rejectSuggestedExample(at index: Int) {
        guard item.aiSuggestedExampleSentences.indices.contains(index) else { return }
        var remaining = item.aiSuggestedExampleSentences
        remaining.remove(at: index)
        viewModel.saveAISuggestedExampleSentences(remaining, for: item)
    }

    private func deleteAcceptedExample(at index: Int) {
        guard item.aiAcceptedExampleSentences.indices.contains(index) else { return }
        acceptedExampleAutosaveTasks[index]?.cancel()
        acceptedExampleAutosaveTasks.removeValue(forKey: index)
        var accepted = item.aiAcceptedExampleSentences
        accepted.remove(at: index)
        viewModel.saveAIAcceptedExampleSentences(accepted, for: item)
    }

    private func acceptSuggestedDefinition() {
        let trimmed = editingSuggestedDefinition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.saveAIAcceptedDefinitionNote(trimmed, for: item)
        viewModel.saveAISuggestedDefinitionNote(nil, for: item)
        editingSuggestedDefinition = ""
    }

    private func rejectSuggestedDefinition() {
        viewModel.saveAISuggestedDefinitionNote(nil, for: item)
        editingSuggestedDefinition = ""
    }

    private func deleteAcceptedDefinition() {
        acceptedDefinitionAutosaveTask?.cancel()
        acceptedDefinitionAutosaveTask = nil
        viewModel.saveAIAcceptedDefinitionNote(nil, for: item)
        editingAcceptedDefinition = ""
    }

    // MARK: - Helpers

    private var firstDefinition: String? {
        guard let result = item.lookupResult else { return nil }
        return sensePromptInputs(from: result).first?.definition
    }

    private func sensePromptInputs(from result: LookupResult) -> [LLMSensePromptInput] {
        var seen = Set<String>()
        var senses: [LLMSensePromptInput] = []

        for entry in result.entries {
            for lexical in entry.lexicalEntries {
                for sense in lexical.senses {
                    let def = sense.definition
                    let trimmedDefinition = def.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedDefinition.isEmpty else { continue }

                    let input = LLMSensePromptInput(
                        partOfSpeech: lexical.partOfSpeechLabel,
                        definition: trimmedDefinition,
                        semanticHint: sense.semanticHint
                    )
                    let key = [
                        input.partOfSpeech.lowercased(),
                        input.definition.lowercased(),
                        (input.semanticHint ?? "").lowercased()
                    ].joined(separator: "|")
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    senses.append(input)
                }
            }
        }

        return senses
    }

    private func syncGeneratingState() {
        item.isGeneratingAI = isGeneratingExamples || isGeneratingUsage
    }

    private func syncExampleDrafts() {
        suggestedExampleDrafts = Dictionary(
            uniqueKeysWithValues: item.aiSuggestedExampleSentences.enumerated().map { index, sentence in
                (index, sentence)
            }
        )
        acceptedExampleDrafts = Dictionary(
            uniqueKeysWithValues: item.aiAcceptedExampleSentences.enumerated().map { index, sentence in
                (index, sentence)
            }
        )
    }

    private func bindingForSuggestedExample(at index: Int) -> Binding<String> {
        Binding(
            get: { suggestedExampleDrafts[index] ?? item.aiSuggestedExampleSentences[safe: index] ?? "" },
            set: { suggestedExampleDrafts[index] = $0 }
        )
    }

    private func bindingForAcceptedExample(at index: Int) -> Binding<String> {
        Binding(
            get: { acceptedExampleDrafts[index] ?? item.aiAcceptedExampleSentences[safe: index] ?? "" },
            set: { acceptedExampleDrafts[index] = $0 }
        )
    }

    private func scheduleAcceptedExampleAutosave(at index: Int, value: String) {
        acceptedExampleAutosaveTasks[index]?.cancel()
        acceptedExampleAutosaveTasks[index] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let current = item.aiAcceptedExampleSentences[safe: index] else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != current else { return }

            var accepted = item.aiAcceptedExampleSentences
            accepted[index] = trimmed
            viewModel.saveAIAcceptedExampleSentences(accepted, for: item)
        }
    }

    private func scheduleAcceptedDefinitionAutosave(_ value: String) {
        acceptedDefinitionAutosaveTask?.cancel()
        acceptedDefinitionAutosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != item.aiAcceptedDefinitionNote else { return }
            viewModel.saveAIAcceptedDefinitionNote(trimmed, for: item)
        }
    }

    @ViewBuilder
    private func generationBadge(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.subheadline.bold())
    }

    @ViewBuilder
    private func sectionSubheader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func errorLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.red)
    }

    @ViewBuilder
    private func streamingCard(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct EditableAITextCard: View {
    @Binding var text: String

    let primaryButtonTitle: String?
    let secondaryButtonTitle: String
    let primaryRole: ButtonRole?
    let secondaryRole: ButtonRole?
    let tagText: String?
    let onTextChange: ((String) -> Void)?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    init(
        text: Binding<String>,
        primaryButtonTitle: String? = nil,
        secondaryButtonTitle: String,
        primaryRole: ButtonRole? = nil,
        secondaryRole: ButtonRole? = .destructive,
        tagText: String? = nil,
        onTextChange: ((String) -> Void)? = nil,
        onPrimary: @escaping () -> Void = {},
        onSecondary: @escaping () -> Void
    ) {
        _text = text
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.primaryRole = primaryRole
        self.secondaryRole = secondaryRole
        self.tagText = tagText
        self.onTextChange = onTextChange
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tagText {
                HStack {
                    Spacer()
                    Text(tagText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.05), in: Capsule())
                }
            }

            TextEditor(text: $text)
                .frame(minHeight: 60)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: text) { newValue in
                    onTextChange?(newValue)
                }

            HStack(spacing: 8) {
                if let primaryButtonTitle {
                    Button(role: primaryRole, action: onPrimary) {
                        Text(primaryButtonTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }

                Button(role: secondaryRole, action: onSecondary) {
                    Text(secondaryButtonTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.05), lineWidth: 1)
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
