import SwiftUI
import DictKit
import DictKitAnkiExport
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
    @State private var suggestedRecallDrafts: [Int: RecallCardDraft] = [:]
    @State private var acceptedRecallDrafts: [Int: RecallCardDraft] = [:]
    @State private var suggestedPitfallDrafts: [Int: String] = [:]
    @State private var acceptedPitfallDrafts: [Int: String] = [:]
    @State private var suggestedMnemonicDrafts: [Int: String] = [:]
    @State private var acceptedMnemonicDrafts: [Int: String] = [:]
    @State private var suggestedCollocationDrafts: [Int: String] = [:]
    @State private var acceptedCollocationDrafts: [Int: String] = [:]
    @State private var examplesTask: Task<Void, Never>?
    @State private var usageTask: Task<Void, Never>?
    @State private var acceptedDefinitionAutosaveTask: Task<Void, Never>?
    @State private var acceptedExampleAutosaveTasks: [Int: Task<Void, Never>] = [:]
    @State private var acceptedRecallAutosaveTasks: [Int: Task<Void, Never>] = [:]
    @State private var acceptedPitfallAutosaveTasks: [Int: Task<Void, Never>] = [:]
    @State private var acceptedMnemonicAutosaveTasks: [Int: Task<Void, Never>] = [:]
    @State private var acceptedCollocationAutosaveTasks: [Int: Task<Void, Never>] = [:]

    private let logger = Logger(subsystem: "AnkiMateApp", category: "AIContentView")

    private var isGeneratingExamples: Bool { examplesTask != nil }
    private var isGeneratingUsage: Bool { usageTask != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Assistant", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    if isGeneratingExamples { generationBadge("Examples") }
                    if isGeneratingUsage { generationBadge("Usage") }
                }
            }

            if !llmService.hasModel {
                noModelView
            } else {
                actionButtons

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionCard { sentencesSection }
                        sectionCard { definitionNoteSection }
                        sectionCard { recallCardSection }
                        sectionCard { pitfallsSection }
                        sectionCard { mnemonicsSection }
                        sectionCard { collocationsSection }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.05), lineWidth: 1))
        .onAppear {
            syncExampleDrafts()
            syncRecallDrafts()
            syncPitfallDrafts()
            syncMnemonicDrafts()
            syncCollocationDrafts()
            editingSuggestedDefinition = item.aiSuggestedDefinitionNote ?? ""
            editingAcceptedDefinition = item.aiAcceptedDefinitionNote ?? ""
            syncGeneratingState()
        }
        .onChange(of: item.aiSuggestedExampleSentences) { _ in syncExampleDrafts() }
        .onChange(of: item.aiAcceptedExampleSentences) { _ in syncExampleDrafts() }
        .onChange(of: item.aiSuggestedDefinitionNote) { newValue in editingSuggestedDefinition = newValue ?? "" }
        .onChange(of: item.aiAcceptedDefinitionNote) { newValue in editingAcceptedDefinition = newValue ?? "" }
        .onChange(of: item.aiSuggestedRecallCardDrafts) { _ in syncRecallDrafts() }
        .onChange(of: item.aiAcceptedRecallCardDrafts) { _ in syncRecallDrafts() }
        .onChange(of: item.aiSuggestedPitfalls) { _ in syncPitfallDrafts() }
        .onChange(of: item.aiAcceptedPitfalls) { _ in syncPitfallDrafts() }
        .onChange(of: item.aiSuggestedMnemonics) { _ in syncMnemonicDrafts() }
        .onChange(of: item.aiAcceptedMnemonics) { _ in syncMnemonicDrafts() }
        .onChange(of: item.aiSuggestedCollocations) { _ in syncCollocationDrafts() }
        .onChange(of: item.aiAcceptedCollocations) { _ in syncCollocationDrafts() }
        .onDisappear {
            examplesTask?.cancel()
            usageTask?.cancel()
            acceptedDefinitionAutosaveTask?.cancel()
            acceptedExampleAutosaveTasks.values.forEach { $0.cancel() }
            acceptedRecallAutosaveTasks.values.forEach { $0.cancel() }
            acceptedPitfallAutosaveTasks.values.forEach { $0.cancel() }
            acceptedMnemonicAutosaveTasks.values.forEach { $0.cancel() }
            acceptedCollocationAutosaveTasks.values.forEach { $0.cancel() }
            examplesTask = nil
            usageTask = nil
            acceptedDefinitionAutosaveTask = nil
            acceptedExampleAutosaveTasks = [:]
            acceptedRecallAutosaveTasks = [:]
            acceptedPitfallAutosaveTasks = [:]
            acceptedMnemonicAutosaveTasks = [:]
            acceptedCollocationAutosaveTasks = [:]
            syncGeneratingState()
        }
    }

    private var noModelView: some View {
        Text("Download and select a model in AI settings to enable AI features.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

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

    private func actionButtonLabel(title: String, systemImage: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.subheadline)
    }

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

            if let examplesErrorMessage { errorLabel(examplesErrorMessage) }

            if !item.aiAcceptedExampleSentences.isEmpty {
                sectionSubheader("Accepted").padding(.top, 2)
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

            if let usageErrorMessage { errorLabel(usageErrorMessage) }

            if item.aiAcceptedDefinitionNote != nil {
                sectionSubheader("Accepted").padding(.top, 2)
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

    private var recallCardSection: some View {
        aiArtifactSection(
            title: "Recall Card",
            suggestedCount: item.aiSuggestedRecallCardDrafts.count,
            acceptedCount: item.aiAcceptedRecallCardDrafts.count,
            suggestedEmptyText: "No recall drafts yet.",
            acceptedEmptyText: "No accepted recall drafts yet."
        ) {
            ForEach(Array(item.aiSuggestedRecallCardDrafts.indices), id: \.self) { index in
                EditableRecallDraftCard(
                    draft: bindingForSuggestedRecallDraft(at: index),
                    primaryButtonTitle: "Accept",
                    secondaryButtonTitle: "Reject",
                    onPrimary: { acceptSuggestedRecallDraft(at: index) },
                    onSecondary: { rejectSuggestedRecallDraft(at: index) }
                )
            }
        } acceptedContent: {
            ForEach(Array(item.aiAcceptedRecallCardDrafts.indices), id: \.self) { index in
                EditableRecallDraftCard(
                    draft: bindingForAcceptedRecallDraft(at: index),
                    secondaryButtonTitle: "Delete",
                    tagText: "AI-generated",
                    onDraftChange: { scheduleAcceptedRecallAutosave(at: index, value: $0) },
                    onSecondary: { deleteAcceptedRecallDraft(at: index) }
                )
            }
        }
    }

    private var pitfallsSection: some View {
        aiTextArtifactSection(
            title: "Pitfalls",
            suggested: item.aiSuggestedPitfalls,
            accepted: item.aiAcceptedPitfalls,
            suggestedEmptyText: "No pitfalls yet.",
            acceptedEmptyText: "No accepted pitfalls yet.",
            suggestedBinding: bindingForSuggestedPitfall(at:),
            acceptedBinding: bindingForAcceptedPitfall(at:),
            accept: acceptSuggestedPitfall(at:),
            reject: rejectSuggestedPitfall(at:),
            delete: deleteAcceptedPitfall(at:),
            scheduleAcceptedAutosave: scheduleAcceptedPitfallAutosave(at:value:)
        )
    }

    private var mnemonicsSection: some View {
        aiTextArtifactSection(
            title: "Mnemonics",
            suggested: item.aiSuggestedMnemonics,
            accepted: item.aiAcceptedMnemonics,
            suggestedEmptyText: "No mnemonics yet.",
            acceptedEmptyText: "No accepted mnemonics yet.",
            suggestedBinding: bindingForSuggestedMnemonic(at:),
            acceptedBinding: bindingForAcceptedMnemonic(at:),
            accept: acceptSuggestedMnemonic(at:),
            reject: rejectSuggestedMnemonic(at:),
            delete: deleteAcceptedMnemonic(at:),
            scheduleAcceptedAutosave: scheduleAcceptedMnemonicAutosave(at:value:)
        )
    }

    private var collocationsSection: some View {
        aiTextArtifactSection(
            title: "Collocations",
            suggested: item.aiSuggestedCollocations,
            accepted: item.aiAcceptedCollocations,
            suggestedEmptyText: "No collocations yet.",
            acceptedEmptyText: "No accepted collocations yet.",
            suggestedBinding: bindingForSuggestedCollocation(at:),
            acceptedBinding: bindingForAcceptedCollocation(at:),
            accept: acceptSuggestedCollocation(at:),
            reject: rejectSuggestedCollocation(at:),
            delete: deleteAcceptedCollocation(at:),
            scheduleAcceptedAutosave: scheduleAcceptedCollocationAutosave(at:value:)
        )
    }

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
                        Task { @MainActor in streamingExamplesText += delta }
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
                        Task { @MainActor in streamingUsageText += delta }
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

    private func acceptSuggestedRecallDraft(at index: Int) {
        guard let suggested = item.aiSuggestedRecallCardDrafts[safe: index] else { return }
        var accepted = item.aiAcceptedRecallCardDrafts
        accepted.append(suggested)
        viewModel.saveAIAcceptedRecallCardDrafts(accepted, for: item)

        var remaining = item.aiSuggestedRecallCardDrafts
        remaining.remove(at: index)
        viewModel.saveAISuggestedRecallCardDrafts(remaining, for: item)
    }

    private func rejectSuggestedRecallDraft(at index: Int) {
        guard item.aiSuggestedRecallCardDrafts.indices.contains(index) else { return }
        var remaining = item.aiSuggestedRecallCardDrafts
        remaining.remove(at: index)
        viewModel.saveAISuggestedRecallCardDrafts(remaining, for: item)
    }

    private func deleteAcceptedRecallDraft(at index: Int) {
        acceptedRecallAutosaveTasks[index]?.cancel()
        acceptedRecallAutosaveTasks.removeValue(forKey: index)
        var drafts = item.aiAcceptedRecallCardDrafts
        drafts.remove(at: index)
        viewModel.saveAIAcceptedRecallCardDrafts(drafts, for: item)
    }

    private func acceptSuggestedPitfall(at index: Int) {
        guard let value = item.aiSuggestedPitfalls[safe: index]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var accepted = item.aiAcceptedPitfalls
        accepted.append(value)
        viewModel.saveAIAcceptedPitfalls(accepted, for: item)

        var remaining = item.aiSuggestedPitfalls
        remaining.remove(at: index)
        viewModel.saveAISuggestedPitfalls(remaining, for: item)
    }

    private func rejectSuggestedPitfall(at index: Int) {
        guard item.aiSuggestedPitfalls.indices.contains(index) else { return }
        var remaining = item.aiSuggestedPitfalls
        remaining.remove(at: index)
        viewModel.saveAISuggestedPitfalls(remaining, for: item)
    }

    private func deleteAcceptedPitfall(at index: Int) {
        acceptedPitfallAutosaveTasks[index]?.cancel()
        acceptedPitfallAutosaveTasks.removeValue(forKey: index)
        var values = item.aiAcceptedPitfalls
        values.remove(at: index)
        viewModel.saveAIAcceptedPitfalls(values, for: item)
    }

    private func acceptSuggestedMnemonic(at index: Int) {
        moveSuggestedString(
            at: index,
            suggestedValues: item.aiSuggestedMnemonics,
            acceptedValues: item.aiAcceptedMnemonics,
            saveSuggested: viewModel.saveAISuggestedMnemonics,
            saveAccepted: viewModel.saveAIAcceptedMnemonics
        )
    }

    private func rejectSuggestedMnemonic(at index: Int) {
        removeSuggestedString(at: index, values: item.aiSuggestedMnemonics, saveSuggested: viewModel.saveAISuggestedMnemonics)
    }

    private func deleteAcceptedMnemonic(at index: Int) {
        acceptedMnemonicAutosaveTasks[index]?.cancel()
        acceptedMnemonicAutosaveTasks.removeValue(forKey: index)
        var values = item.aiAcceptedMnemonics
        values.remove(at: index)
        viewModel.saveAIAcceptedMnemonics(values, for: item)
    }

    private func acceptSuggestedCollocation(at index: Int) {
        moveSuggestedString(
            at: index,
            suggestedValues: item.aiSuggestedCollocations,
            acceptedValues: item.aiAcceptedCollocations,
            saveSuggested: viewModel.saveAISuggestedCollocations,
            saveAccepted: viewModel.saveAIAcceptedCollocations
        )
    }

    private func rejectSuggestedCollocation(at index: Int) {
        removeSuggestedString(at: index, values: item.aiSuggestedCollocations, saveSuggested: viewModel.saveAISuggestedCollocations)
    }

    private func deleteAcceptedCollocation(at index: Int) {
        acceptedCollocationAutosaveTasks[index]?.cancel()
        acceptedCollocationAutosaveTasks.removeValue(forKey: index)
        var values = item.aiAcceptedCollocations
        values.remove(at: index)
        viewModel.saveAIAcceptedCollocations(values, for: item)
    }

    private func syncExampleDrafts() {
        suggestedExampleDrafts = Dictionary(uniqueKeysWithValues: item.aiSuggestedExampleSentences.enumerated().map { ($0.offset, $0.element) })
        acceptedExampleDrafts = Dictionary(uniqueKeysWithValues: item.aiAcceptedExampleSentences.enumerated().map { ($0.offset, $0.element) })
    }

    private func syncRecallDrafts() {
        suggestedRecallDrafts = Dictionary(uniqueKeysWithValues: item.aiSuggestedRecallCardDrafts.enumerated().map { ($0.offset, $0.element) })
        acceptedRecallDrafts = Dictionary(uniqueKeysWithValues: item.aiAcceptedRecallCardDrafts.enumerated().map { ($0.offset, $0.element) })
    }

    private func syncPitfallDrafts() {
        suggestedPitfallDrafts = Dictionary(uniqueKeysWithValues: item.aiSuggestedPitfalls.enumerated().map { ($0.offset, $0.element) })
        acceptedPitfallDrafts = Dictionary(uniqueKeysWithValues: item.aiAcceptedPitfalls.enumerated().map { ($0.offset, $0.element) })
    }

    private func syncMnemonicDrafts() {
        suggestedMnemonicDrafts = Dictionary(uniqueKeysWithValues: item.aiSuggestedMnemonics.enumerated().map { ($0.offset, $0.element) })
        acceptedMnemonicDrafts = Dictionary(uniqueKeysWithValues: item.aiAcceptedMnemonics.enumerated().map { ($0.offset, $0.element) })
    }

    private func syncCollocationDrafts() {
        suggestedCollocationDrafts = Dictionary(uniqueKeysWithValues: item.aiSuggestedCollocations.enumerated().map { ($0.offset, $0.element) })
        acceptedCollocationDrafts = Dictionary(uniqueKeysWithValues: item.aiAcceptedCollocations.enumerated().map { ($0.offset, $0.element) })
    }

    private func bindingForSuggestedExample(at index: Int) -> Binding<String> {
        Binding(get: { suggestedExampleDrafts[index] ?? item.aiSuggestedExampleSentences[safe: index] ?? "" }, set: { suggestedExampleDrafts[index] = $0 })
    }

    private func bindingForAcceptedExample(at index: Int) -> Binding<String> {
        Binding(get: { acceptedExampleDrafts[index] ?? item.aiAcceptedExampleSentences[safe: index] ?? "" }, set: { acceptedExampleDrafts[index] = $0 })
    }

    private func bindingForSuggestedRecallDraft(at index: Int) -> Binding<RecallCardDraft> {
        Binding(get: { suggestedRecallDrafts[index] ?? item.aiSuggestedRecallCardDrafts[safe: index] ?? RecallCardDraft(mode: .phraseRecall, front: "", back: "") }, set: { suggestedRecallDrafts[index] = $0 })
    }

    private func bindingForAcceptedRecallDraft(at index: Int) -> Binding<RecallCardDraft> {
        Binding(get: { acceptedRecallDrafts[index] ?? item.aiAcceptedRecallCardDrafts[safe: index] ?? RecallCardDraft(mode: .phraseRecall, front: "", back: "") }, set: { acceptedRecallDrafts[index] = $0 })
    }

    private func bindingForSuggestedPitfall(at index: Int) -> Binding<String> {
        Binding(get: { suggestedPitfallDrafts[index] ?? item.aiSuggestedPitfalls[safe: index] ?? "" }, set: { suggestedPitfallDrafts[index] = $0 })
    }

    private func bindingForAcceptedPitfall(at index: Int) -> Binding<String> {
        Binding(get: { acceptedPitfallDrafts[index] ?? item.aiAcceptedPitfalls[safe: index] ?? "" }, set: { acceptedPitfallDrafts[index] = $0 })
    }

    private func bindingForSuggestedMnemonic(at index: Int) -> Binding<String> {
        Binding(get: { suggestedMnemonicDrafts[index] ?? item.aiSuggestedMnemonics[safe: index] ?? "" }, set: { suggestedMnemonicDrafts[index] = $0 })
    }

    private func bindingForAcceptedMnemonic(at index: Int) -> Binding<String> {
        Binding(get: { acceptedMnemonicDrafts[index] ?? item.aiAcceptedMnemonics[safe: index] ?? "" }, set: { acceptedMnemonicDrafts[index] = $0 })
    }

    private func bindingForSuggestedCollocation(at index: Int) -> Binding<String> {
        Binding(get: { suggestedCollocationDrafts[index] ?? item.aiSuggestedCollocations[safe: index] ?? "" }, set: { suggestedCollocationDrafts[index] = $0 })
    }

    private func bindingForAcceptedCollocation(at index: Int) -> Binding<String> {
        Binding(get: { acceptedCollocationDrafts[index] ?? item.aiAcceptedCollocations[safe: index] ?? "" }, set: { acceptedCollocationDrafts[index] = $0 })
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

    private func scheduleAcceptedRecallAutosave(at index: Int, value: RecallCardDraft) {
        acceptedRecallAutosaveTasks[index]?.cancel()
        acceptedRecallAutosaveTasks[index] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let current = item.aiAcceptedRecallCardDrafts[safe: index], current != value else { return }
            var drafts = item.aiAcceptedRecallCardDrafts
            drafts[index] = value
            viewModel.saveAIAcceptedRecallCardDrafts(drafts, for: item)
        }
    }

    private func scheduleAcceptedPitfallAutosave(at index: Int, value: String) {
        acceptedPitfallAutosaveTasks[index]?.cancel()
        acceptedPitfallAutosaveTasks[index] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != item.aiAcceptedPitfalls[safe: index] else { return }
            var values = item.aiAcceptedPitfalls
            values[index] = trimmed
            viewModel.saveAIAcceptedPitfalls(values, for: item)
        }
    }

    private func scheduleAcceptedMnemonicAutosave(at index: Int, value: String) {
        acceptedMnemonicAutosaveTasks[index]?.cancel()
        acceptedMnemonicAutosaveTasks[index] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != item.aiAcceptedMnemonics[safe: index] else { return }
            var values = item.aiAcceptedMnemonics
            values[index] = trimmed
            viewModel.saveAIAcceptedMnemonics(values, for: item)
        }
    }

    private func scheduleAcceptedCollocationAutosave(at index: Int, value: String) {
        acceptedCollocationAutosaveTasks[index]?.cancel()
        acceptedCollocationAutosaveTasks[index] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != item.aiAcceptedCollocations[safe: index] else { return }
            var values = item.aiAcceptedCollocations
            values[index] = trimmed
            viewModel.saveAIAcceptedCollocations(values, for: item)
        }
    }

    private func syncGeneratingState() {
        item.isGeneratingAI = isGeneratingExamples || isGeneratingUsage
    }

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
                    let trimmedDefinition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    guard seen.insert(key).inserted else { continue }
                    senses.append(input)
                }
            }
        }

        return senses
    }

    private func moveSuggestedString(
        at index: Int,
        suggestedValues: [String],
        acceptedValues: [String],
        saveSuggested: ([String], WordItem) -> Void,
        saveAccepted: ([String], WordItem) -> Void
    ) {
        guard let value = suggestedValues[safe: index]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var accepted = acceptedValues
        accepted.append(value)
        saveAccepted(accepted, item)
        removeSuggestedString(at: index, values: suggestedValues, saveSuggested: saveSuggested)
    }

    private func removeSuggestedString(at index: Int, values: [String], saveSuggested: ([String], WordItem) -> Void) {
        guard values.indices.contains(index) else { return }
        var remaining = values
        remaining.remove(at: index)
        saveSuggested(remaining, item)
    }

    private func aiArtifactSection<SuggestedContent: View, AcceptedContent: View>(
        title: String,
        suggestedCount: Int,
        acceptedCount: Int,
        suggestedEmptyText: String,
        acceptedEmptyText: String,
        @ViewBuilder suggestedContent: () -> SuggestedContent,
        @ViewBuilder acceptedContent: () -> AcceptedContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: title)
            if suggestedCount > 0 {
                sectionSubheader("Suggested")
                suggestedContent()
            } else {
                emptyState(suggestedEmptyText)
            }
            if acceptedCount > 0 {
                sectionSubheader("Accepted").padding(.top, 2)
                acceptedContent()
            } else {
                emptyState(acceptedEmptyText)
            }
        }
    }

    private func aiTextArtifactSection(
        title: String,
        suggested: [String],
        accepted: [String],
        suggestedEmptyText: String,
        acceptedEmptyText: String,
        suggestedBinding: @escaping (Int) -> Binding<String>,
        acceptedBinding: @escaping (Int) -> Binding<String>,
        accept: @escaping (Int) -> Void,
        reject: @escaping (Int) -> Void,
        delete: @escaping (Int) -> Void,
        scheduleAcceptedAutosave: @escaping (Int, String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: title)
            if !suggested.isEmpty {
                sectionSubheader("Suggested")
                ForEach(Array(suggested.indices), id: \.self) { index in
                    EditableAITextCard(
                        text: suggestedBinding(index),
                        primaryButtonTitle: "Accept",
                        secondaryButtonTitle: "Reject",
                        onPrimary: { accept(index) },
                        onSecondary: { reject(index) }
                    )
                }
            } else {
                emptyState(suggestedEmptyText)
            }
            if !accepted.isEmpty {
                sectionSubheader("Accepted").padding(.top, 2)
                ForEach(Array(accepted.indices), id: \.self) { index in
                    EditableAITextCard(
                        text: acceptedBinding(index),
                        secondaryButtonTitle: "Delete",
                        tagText: "AI-generated",
                        onTextChange: { scheduleAcceptedAutosave(index, $0) },
                        onSecondary: { delete(index) }
                    )
                }
            } else {
                emptyState(acceptedEmptyText)
            }
        }
    }

    private func generationBadge(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.05), lineWidth: 1))
    }

    private func sectionHeader(title: String) -> some View {
        Text(title).font(.subheadline.bold())
    }

    private func sectionSubheader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func errorLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.red)
    }

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
                .onChange(of: text) { newValue in onTextChange?(newValue) }

            HStack(spacing: 8) {
                if let primaryButtonTitle {
                    Button(role: primaryRole, action: onPrimary) { Text(primaryButtonTitle) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
                Button(role: secondaryRole, action: onSecondary) { Text(secondaryButtonTitle) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.05), lineWidth: 1))
    }
}

private struct EditableRecallDraftCard: View {
    @Binding var draft: RecallCardDraft

    let primaryButtonTitle: String?
    let secondaryButtonTitle: String
    let tagText: String?
    let onDraftChange: ((RecallCardDraft) -> Void)?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    init(
        draft: Binding<RecallCardDraft>,
        primaryButtonTitle: String? = nil,
        secondaryButtonTitle: String,
        tagText: String? = nil,
        onDraftChange: ((RecallCardDraft) -> Void)? = nil,
        onPrimary: @escaping () -> Void = {},
        onSecondary: @escaping () -> Void
    ) {
        _draft = draft
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.tagText = tagText
        self.onDraftChange = onDraftChange
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

            modePicker
            frontField
            backField
            hintField

            HStack(spacing: 8) {
                if let primaryButtonTitle {
                    Button(action: onPrimary) { Text(primaryButtonTitle) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                }
                Button(role: .destructive, action: onSecondary) { Text(secondaryButtonTitle) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.05), lineWidth: 1))
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { draft.mode },
            set: { next in updateDraft(mode: next) }
        )) {
            ForEach(RecallCardMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var frontField: some View {
        TextField("Front", text: Binding(
            get: { draft.front },
            set: { updateDraft(front: $0) }
        ))
    }

    private var backField: some View {
        TextField("Back", text: Binding(
            get: { draft.back },
            set: { updateDraft(back: $0) }
        ))
    }

    private var hintField: some View {
        TextField("Hint", text: Binding(
            get: { draft.hint ?? "" },
            set: { next in
                let hint = next.trimmingCharacters(in: .whitespacesAndNewlines)
                updateDraft(hint: hint.isEmpty ? nil : hint)
            }
        ))
    }

    private func updateDraft(
        mode: RecallCardMode? = nil,
        front: String? = nil,
        back: String? = nil,
        hint: String? = nil
    ) {
        draft = RecallCardDraft(
            mode: mode ?? draft.mode,
            front: front ?? draft.front,
            back: back ?? draft.back,
            hint: hint ?? draft.hint,
            anchor: draft.anchor
        )
        onDraftChange?(draft)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
