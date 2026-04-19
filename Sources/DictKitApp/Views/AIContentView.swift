import SwiftUI
import DictKit
import DictKitAnkiExport
import AnkiMateLLM
import AppKit
import os

struct AIInlineTextDraftState: Equatable {
    var draft: String = ""
    var lastPersistedValue: String = ""

    var isDirty: Bool {
        draft != lastPersistedValue
    }

    mutating func updateDraft(_ value: String) {
        draft = value
    }

    mutating func mergePersistedValue(_ value: String) {
        let wasDirty = isDirty
        lastPersistedValue = value
        if !wasDirty || draft == value {
            draft = value
        }
    }
}

struct AIDraftListState<Persisted: Equatable, Draft: Equatable>: Equatable {
    var rowOrder: [UUID] = []
    var drafts: [UUID: Draft] = [:]
    var persistedByRowID: [UUID: Persisted] = [:]
}

struct AIDraftListSyncResult<Persisted: Equatable, Draft: Equatable>: Equatable {
    let state: AIDraftListState<Persisted, Draft>
    let removedRowIDs: [UUID]
}

enum AIDraftListSynchronizer {
    static func sync<Persisted: Equatable, Draft: Equatable>(
        persistedValues: [Persisted],
        currentState: AIDraftListState<Persisted, Draft>,
        draftValue: (Persisted) -> Draft,
        matchesDraft: ((Persisted, Draft) -> Bool)? = nil
    ) -> AIDraftListSyncResult<Persisted, Draft> {
        var remainingRowIDs = currentState.rowOrder
        var nextRowOrder: [UUID] = []
        var nextDrafts: [UUID: Draft] = [:]
        var nextPersistedByRowID: [UUID: Persisted] = [:]

        for value in persistedValues {
            let matchedRowID = matchRowID(
                for: value,
                remainingRowIDs: &remainingRowIDs,
                currentState: currentState,
                draftValue: draftValue,
                matchesDraft: matchesDraft
            ) ?? UUID()

            let previousPersisted = currentState.persistedByRowID[matchedRowID]
            let previousDraft = currentState.drafts[matchedRowID]
            let nextDraft: Draft

            if let previousDraft, let previousPersisted {
                let previousPersistedDraft = draftValue(previousPersisted)
                let wasDirty = previousDraft != previousPersistedDraft
                let nextPersistedDraft = draftValue(value)
                nextDraft = wasDirty && previousDraft != nextPersistedDraft
                    ? previousDraft
                    : nextPersistedDraft
            } else {
                nextDraft = draftValue(value)
            }

            nextRowOrder.append(matchedRowID)
            nextDrafts[matchedRowID] = nextDraft
            nextPersistedByRowID[matchedRowID] = value
        }

        return AIDraftListSyncResult(
            state: AIDraftListState(
                rowOrder: nextRowOrder,
                drafts: nextDrafts,
                persistedByRowID: nextPersistedByRowID
            ),
            removedRowIDs: remainingRowIDs
        )
    }

    private static func matchRowID<Persisted: Equatable, Draft: Equatable>(
        for value: Persisted,
        remainingRowIDs: inout [UUID],
        currentState: AIDraftListState<Persisted, Draft>,
        draftValue: (Persisted) -> Draft,
        matchesDraft: ((Persisted, Draft) -> Bool)?
    ) -> UUID? {
        if let rowID = remainingRowIDs.first(where: { currentState.persistedByRowID[$0] == value }) {
            remainingRowIDs.removeAll { $0 == rowID }
            return rowID
        }

        if let rowID = remainingRowIDs.first(where: {
            guard let draft = currentState.drafts[$0] else { return false }
            if let matchesDraft {
                return matchesDraft(value, draft)
            }
            return draftValue(value) == draft
        }) {
            remainingRowIDs.removeAll { $0 == rowID }
            return rowID
        }

        return nil
    }
}

struct RecallDraftEditorUpdate {
    var mode: RecallCardMode?
    var front: String?
    var back: String?
    var hint: String??

    static func mode(_ value: RecallCardMode) -> RecallDraftEditorUpdate {
        RecallDraftEditorUpdate(mode: value)
    }

    static func front(_ value: String) -> RecallDraftEditorUpdate {
        RecallDraftEditorUpdate(front: value)
    }

    static func back(_ value: String) -> RecallDraftEditorUpdate {
        RecallDraftEditorUpdate(back: value)
    }

    static func hint(_ value: String?) -> RecallDraftEditorUpdate {
        RecallDraftEditorUpdate(hint: .some(value))
    }
}

enum RecallDraftEditorReducer {
    static func applying(
        _ update: RecallDraftEditorUpdate,
        to draft: RecallCardDraft,
        selectedMode: RecallCardMode
    ) -> RecallCardDraft {
        RecallCardDraft(
            mode: update.mode ?? selectedMode,
            front: update.front ?? draft.front,
            back: update.back ?? draft.back,
            hint: update.hint ?? draft.hint,
            anchor: draft.anchor
        )
    }
}

enum AIExampleArtifactEditor {
    static func artifact(byApplyingEditedText text: String, to artifact: ExampleSentenceArtifact) -> ExampleSentenceArtifact {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExampleSentenceArtifact(
            text: trimmedText,
            translation: inferredTranslation(from: trimmedText),
            note: artifact.note,
            anchor: artifact.anchor
        )
    }

    static func inferredTranslation(from text: String) -> String? {
        guard let separatorRange = text.range(of: "—", options: .backwards) else { return nil }

        let sourceText = text[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let translationText = text[separatorRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty, !translationText.isEmpty else { return nil }
        return translationText
    }
}

private struct ExampleSenseContext: Equatable {
    let partOfSpeech: String
    let definition: String
    let semanticHint: String?
    let anchor: AIArtifactAnchorSnapshot

    var promptInput: LLMSensePromptInput {
        LLMSensePromptInput(
            partOfSpeech: partOfSpeech,
            definition: definition,
            semanticHint: semanticHint
        )
    }

    var key: String {
        [
            anchor.headword ?? "",
            String(anchor.lexicalEntryIndex ?? -1),
            String(anchor.senseIndex ?? -1)
        ].joined(separator: "|")
    }
}

private struct SectionHeaderAction {
    let title: String
    let systemImage: String
    let isLoading: Bool
    let isDisabled: Bool
    let handler: () -> Void
}

struct AIContentView: View {
    @ObservedObject var item: WordItem
    @EnvironmentObject private var llmService: LLMService
    @EnvironmentObject private var viewModel: WordListViewModel

    @State private var examplesErrorMessage: String?
    @State private var learningAidsErrorMessage: String?
    @State private var usageErrorMessage: String?
    @State private var recallErrorMessage: String?
    @State private var suggestedDefinitionState = AIInlineTextDraftState()
    @State private var acceptedDefinitionState = AIInlineTextDraftState()
    @State private var streamingExamplesText = ""
    @State private var streamingUsageText = ""
    @State private var suggestedExampleState = AIDraftListState<ExampleSentenceArtifact, String>()
    @State private var acceptedExampleState = AIDraftListState<ExampleSentenceArtifact, String>()
    @State private var suggestedRecallState = AIDraftListState<RecallCardDraft, RecallCardDraft>()
    @State private var acceptedRecallState = AIDraftListState<RecallCardDraft, RecallCardDraft>()
    @State private var pendingAcceptedRecallPersistedEcho: RecallCardDraft?
    @State private var suggestedPitfallState = AIDraftListState<String, String>()
    @State private var acceptedPitfallState = AIDraftListState<String, String>()
    @State private var suggestedMnemonicState = AIDraftListState<String, String>()
    @State private var acceptedMnemonicState = AIDraftListState<String, String>()
    @State private var suggestedCollocationState = AIDraftListState<String, String>()
    @State private var acceptedCollocationState = AIDraftListState<String, String>()
    @State private var examplesTask: Task<Void, Never>?
    @State private var learningAidsTask: Task<Void, Never>?
    @State private var usageTask: Task<Void, Never>?
    @State private var recallTask: Task<Void, Never>?
    @State private var acceptedDefinitionAutosaveTask: Task<Void, Never>?
    @State private var acceptedExampleAutosaveTasks: [UUID: Task<Void, Never>] = [:]
    @State private var acceptedRecallAutosaveTasks: [UUID: Task<Void, Never>] = [:]
    @State private var acceptedPitfallAutosaveTasks: [UUID: Task<Void, Never>] = [:]
    @State private var acceptedMnemonicAutosaveTasks: [UUID: Task<Void, Never>] = [:]
    @State private var acceptedCollocationAutosaveTasks: [UUID: Task<Void, Never>] = [:]
    @State private var isExamplesSectionExpanded = true
    @State private var isLearningAidsSectionExpanded = false
    @State private var isUsageSectionExpanded = false
    @State private var isRecallSectionExpanded = false

    private let logger = Logger(subsystem: "AnkiMateApp", category: "AIContentView")

    private var isGeneratingExamples: Bool { examplesTask != nil }
    private var isGeneratingLearningAids: Bool { learningAidsTask != nil }
    private var isGeneratingUsage: Bool { usageTask != nil }
    private var isGeneratingRecall: Bool { recallTask != nil }
    private var suggestedExampleArtifacts: [ExampleSentenceArtifact] { item.aiSuggestedExampleArtifacts }
    private var acceptedExampleArtifacts: [ExampleSentenceArtifact] { item.aiAcceptedExampleArtifacts }
    private var currentExampleSenseContexts: [ExampleSenseContext] {
        guard let result = item.lookupResult else { return [] }
        return exampleSenseContexts(from: result)
    }
    private var hasAcceptedLearningAids: Bool {
        !item.aiAcceptedPitfalls.isEmpty ||
            !item.aiAcceptedMnemonics.isEmpty ||
            !item.aiAcceptedCollocations.isEmpty
    }
    private var primarySuggestedRecallDraftRowID: UUID? {
        suggestedRecallState.rowOrder.first
    }
    private var primaryAcceptedRecallDraftRowID: UUID? {
        acceptedRecallState.rowOrder.first
    }
    private var hasCompatibilityRecallDrafts: Bool {
        suggestedRecallState.rowOrder.count > 1 || acceptedRecallState.rowOrder.count > 1
    }
    private var hasSavedUsageNote: Bool {
        !(item.aiAcceptedDefinitionNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    private var hasSuggestedUsageNote: Bool {
        !(item.aiSuggestedDefinitionNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    private var examplesSectionSummary: String {
        sectionSummary(
            savedCount: acceptedExampleState.rowOrder.count,
            suggestedCount: suggestedExampleState.rowOrder.count,
            isGenerating: isGeneratingExamples
        )
    }
    private var learningAidsSectionSummary: String {
        if isGeneratingLearningAids {
            return "generating"
        }
        let savedParts = [
            countSummary(item.aiAcceptedPitfalls.count, singular: "pitfall"),
            countSummary(item.aiAcceptedMnemonics.count, singular: "mnemonic"),
            countSummary(item.aiAcceptedCollocations.count, singular: "collocation")
        ].compactMap { $0 }

        if !savedParts.isEmpty {
            return savedParts.joined(separator: ", ")
        }

        let suggestionCount = suggestedPitfallState.rowOrder.count + suggestedMnemonicState.rowOrder.count + suggestedCollocationState.rowOrder.count
        return suggestionCount > 0 ? "\(suggestionCount) suggestions" : "empty"
    }
    private var usageSectionSummary: String {
        if hasSavedUsageNote && hasSuggestedUsageNote {
            return "saved + new draft"
        }
        if hasSavedUsageNote {
            return "saved"
        }
        if hasSuggestedUsageNote {
            return "draft ready"
        }
        if isGeneratingUsage {
            return "generating"
        }
        return "empty"
    }
    private var recallSectionSummary: String {
        let hasSaved = primaryAcceptedRecallDraftRowID != nil
        let hasDraft = primarySuggestedRecallDraftRowID != nil

        if hasSaved && hasDraft {
            return "saved + new draft"
        }
        if hasSaved {
            return "saved"
        }
        if hasDraft {
            return "draft ready"
        }
        if hasCompatibilityRecallDrafts {
            return "legacy drafts"
        }
        if isGeneratingRecall {
            return "generating"
        }
        return "empty"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Assistant", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    if isGeneratingExamples { generationBadge("Examples") }
                    if isGeneratingLearningAids { generationBadge("Learning Aids") }
                    if isGeneratingUsage { generationBadge("Usage") }
                    if isGeneratingRecall { generationBadge("Recall") }
                }
            }

            if !llmService.hasModel {
                noModelView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionCard { sentencesSection }
                        sectionCard { learningAidsSection }
                        sectionCard { definitionNoteSection }
                        sectionCard { recallCardSection }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.05), lineWidth: 1))
        .onAppear {
            reloadPanelStateForCurrentItem(resetTransientFeedback: false)
        }
        .onChange(of: item.aiSuggestedExampleArtifacts) { _ in syncExampleDrafts() }
        .onChange(of: item.aiAcceptedExampleArtifacts) { _ in syncExampleDrafts() }
        .onChange(of: item.aiSuggestedDefinitionNote) { newValue in
            suggestedDefinitionState.mergePersistedValue(newValue ?? "")
        }
        .onChange(of: item.aiAcceptedDefinitionNote) { newValue in
            acceptedDefinitionState.mergePersistedValue(newValue ?? "")
            if newValue != nil { isUsageSectionExpanded = true }
        }
        .onChange(of: item.aiSuggestedRecallCardDrafts) { _ in syncRecallDrafts() }
        .onChange(of: item.aiAcceptedRecallCardDrafts) { _ in
            if consumeAcceptedRecallPersistedEchoIfNeeded() {
                if !item.aiAcceptedRecallCardDrafts.isEmpty { isRecallSectionExpanded = true }
                return
            }
            syncRecallDrafts()
            if !item.aiAcceptedRecallCardDrafts.isEmpty { isRecallSectionExpanded = true }
        }
        .onChange(of: item.aiSuggestedPitfalls) { _ in syncPitfallDrafts() }
        .onChange(of: item.aiAcceptedPitfalls) { _ in
            syncPitfallDrafts()
            if hasAcceptedLearningAids { isLearningAidsSectionExpanded = true }
        }
        .onChange(of: item.aiSuggestedMnemonics) { _ in syncMnemonicDrafts() }
        .onChange(of: item.aiAcceptedMnemonics) { _ in
            syncMnemonicDrafts()
            if hasAcceptedLearningAids { isLearningAidsSectionExpanded = true }
        }
        .onChange(of: item.aiSuggestedCollocations) { _ in syncCollocationDrafts() }
        .onChange(of: item.aiAcceptedCollocations) { _ in
            syncCollocationDrafts()
            if hasAcceptedLearningAids { isLearningAidsSectionExpanded = true }
        }
        .onChange(of: item.id) { _ in
            reloadPanelStateForCurrentItem(resetTransientFeedback: true)
        }
        .onDisappear {
            cancelTransientTasks()
            syncGeneratingState()
        }
    }

    private func reloadPanelStateForCurrentItem(resetTransientFeedback: Bool) {
        cancelTransientTasks()
        if resetTransientFeedback {
            examplesErrorMessage = nil
            learningAidsErrorMessage = nil
            usageErrorMessage = nil
            recallErrorMessage = nil
            streamingExamplesText = ""
            streamingUsageText = ""
        }

        syncExampleDrafts()
        syncRecallDrafts()
        syncPitfallDrafts()
        syncMnemonicDrafts()
        syncCollocationDrafts()
        suggestedDefinitionState.mergePersistedValue(item.aiSuggestedDefinitionNote ?? "")
        acceptedDefinitionState.mergePersistedValue(item.aiAcceptedDefinitionNote ?? "")
        syncDisclosureState()
        syncGeneratingState()
    }

    private func cancelTransientTasks() {
        examplesTask?.cancel()
        learningAidsTask?.cancel()
        usageTask?.cancel()
        recallTask?.cancel()
        acceptedDefinitionAutosaveTask?.cancel()
        acceptedExampleAutosaveTasks.values.forEach { $0.cancel() }
        acceptedRecallAutosaveTasks.values.forEach { $0.cancel() }
        acceptedPitfallAutosaveTasks.values.forEach { $0.cancel() }
        acceptedMnemonicAutosaveTasks.values.forEach { $0.cancel() }
        acceptedCollocationAutosaveTasks.values.forEach { $0.cancel() }
        examplesTask = nil
        learningAidsTask = nil
        usageTask = nil
        recallTask = nil
        acceptedDefinitionAutosaveTask = nil
        acceptedExampleAutosaveTasks = [:]
        acceptedRecallAutosaveTasks = [:]
        acceptedPitfallAutosaveTasks = [:]
        acceptedMnemonicAutosaveTasks = [:]
        acceptedCollocationAutosaveTasks = [:]
    }

    private func syncDisclosureState() {
        isExamplesSectionExpanded = true
        isLearningAidsSectionExpanded = hasAcceptedLearningAids
        isUsageSectionExpanded = hasSavedUsageNote
        isRecallSectionExpanded = !item.aiAcceptedRecallCardDrafts.isEmpty || !item.aiSuggestedRecallCardDrafts.isEmpty
    }

    private var noModelView: some View {
        Text("Download and select a model in AI settings to enable AI features.")
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func compactActionButtonLabel(systemImage: String, isLoading: Bool) -> some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
        }
        .frame(width: 14, height: 14)
    }

    private var sentencesSection: some View {
        DisclosureGroup(isExpanded: $isExamplesSectionExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                sectionDescription("Natural example contexts.")

                if !suggestedExampleState.rowOrder.isEmpty {
                    sectionSubheader("Suggestions")
                    ForEach(suggestedExampleState.rowOrder, id: \.self) { rowID in
                        if let artifact = suggestedExampleState.persistedByRowID[rowID] {
                            EditableAITextCard(
                                text: bindingForSuggestedExample(rowID: rowID),
                                primaryButtonTitle: "Save",
                                secondaryButtonTitle: "Dismiss",
                                tagText: exampleTagText(
                                    for: artifact,
                                    among: suggestedExampleArtifacts
                                ),
                                editorHeight: 68,
                                onPrimary: { acceptSuggestedExample(rowID: rowID) },
                                onSecondary: { rejectSuggestedExample(rowID: rowID) }
                            )
                        }
                    }
                } else if isGeneratingExamples && !streamingExamplesText.isEmpty {
                    sectionSubheader("Streaming")
                    streamingCard(streamingExamplesText)
                } else if isGeneratingExamples {
                    generatingState("Generating suggestions...")
                } else {
                    emptyState("No example suggestions yet.")
                }

                if let examplesErrorMessage { errorLabel(examplesErrorMessage) }

                if !acceptedExampleState.rowOrder.isEmpty {
                    sectionSubheader("Saved").padding(.top, 2)
                    ForEach(acceptedExampleState.rowOrder, id: \.self) { rowID in
                        if let artifact = acceptedExampleState.persistedByRowID[rowID] {
                            EditableAITextCard(
                                text: bindingForAcceptedExample(rowID: rowID),
                                secondaryButtonTitle: "Delete",
                                tagText: exampleTagText(
                                    for: artifact,
                                    among: acceptedExampleArtifacts
                                ),
                                editorHeight: 46,
                                onTextChange: { scheduleAcceptedExampleAutosave(rowID: rowID, value: $0) },
                                onSecondary: { deleteAcceptedExample(rowID: rowID) }
                            )
                        }
                    }
                }
            }
        } label: {
            topLevelSectionLabel(
                title: "Examples",
                summary: examplesSectionSummary,
                action: .init(
                    title: isGeneratingExamples ? "Generating..." : "Regenerate",
                    systemImage: "text.quote",
                    isLoading: isGeneratingExamples,
                    isDisabled: isGeneratingExamples,
                    handler: generateSentences
                )
            )
        }
    }

    private var definitionNoteSection: some View {
        DisclosureGroup(isExpanded: $isUsageSectionExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                sectionDescription("Short learner-facing usage cue.")

                if hasSuggestedUsageNote {
                    sectionSubheader("Suggestion")
                    EditableAITextCard(
                        text: bindingForSuggestedDefinition(),
                        primaryButtonTitle: "Save",
                        secondaryButtonTitle: "Dismiss",
                        onPrimary: acceptSuggestedDefinition,
                        onSecondary: rejectSuggestedDefinition
                    )
                } else if isGeneratingUsage && !streamingUsageText.isEmpty {
                    sectionSubheader("Streaming")
                    streamingCard(streamingUsageText)
                } else {
                    emptyState("No usage cue yet.")
                }

                if let usageErrorMessage { errorLabel(usageErrorMessage) }

                if hasSavedUsageNote {
                    sectionSubheader("Saved").padding(.top, 2)
                    EditableAITextCard(
                        text: bindingForAcceptedDefinition(),
                        secondaryButtonTitle: "Delete",
                        tagText: "Usage cue",
                        onTextChange: scheduleAcceptedDefinitionAutosave,
                        onSecondary: deleteAcceptedDefinition
                    )
                }
            }
        } label: {
            topLevelSectionLabel(
                title: "Usage",
                summary: usageSectionSummary,
                action: .init(
                    title: isGeneratingUsage ? "Generating..." : "Regenerate",
                    systemImage: "text.magnifyingglass",
                    isLoading: isGeneratingUsage,
                    isDisabled: isGeneratingUsage || firstDefinition == nil,
                    handler: optimizeDefinition
                )
            )
        }
    }

    private var recallCardSection: some View {
        DisclosureGroup(isExpanded: $isRecallSectionExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                sectionDescription("One active-recall card.")

                if let rowID = primaryAcceptedRecallDraftRowID {
                    workspaceSubsectionHeader(
                        title: "Saved Recall Card",
                        caption: "Editing here updates the saved Recall card used by preview and export."
                    )
                    EditableRecallDraftCard(
                        draft: bindingForAcceptedRecallDraft(rowID: rowID),
                        secondaryButtonTitle: "Delete Saved Card",
                        tagText: "Saved",
                        onModeChange: { persistAcceptedRecallModeChange(rowID: rowID, value: $0) },
                        onDraftChange: { scheduleAcceptedRecallAutosave(rowID: rowID, value: $0) },
                        onSecondary: { deleteAcceptedRecallDraft(rowID: rowID) }
                    )
                } else if let rowID = primarySuggestedRecallDraftRowID {
                    workspaceSubsectionHeader(
                        title: "Draft",
                        caption: "Review the current draft, then save it as the Recall card when it is ready."
                    )
                    EditableRecallDraftCard(
                        draft: bindingForSuggestedRecallDraft(rowID: rowID),
                        primaryButtonTitle: "Save Recall Card",
                        secondaryButtonTitle: "Discard Draft",
                        tagText: "Draft",
                        onPrimary: { saveSuggestedRecallDraft(rowID: rowID) },
                        onSecondary: { rejectSuggestedRecallDraft(rowID: rowID) }
                    )
                } else {
                    emptyState("No recall draft yet. Generate one to start the workspace.")
                }

                if primaryAcceptedRecallDraftRowID != nil, let rowID = primarySuggestedRecallDraftRowID {
                    workspaceSubsectionHeader(
                        title: "Replacement Draft",
                        caption: "Save this draft to replace the current saved Recall card."
                    )
                    EditableRecallDraftCard(
                        draft: bindingForSuggestedRecallDraft(rowID: rowID),
                        primaryButtonTitle: "Replace Recall Card",
                        secondaryButtonTitle: "Discard Draft",
                        tagText: "Draft",
                        onPrimary: { saveSuggestedRecallDraft(rowID: rowID) },
                        onSecondary: { rejectSuggestedRecallDraft(rowID: rowID) }
                    )
                }

                if hasCompatibilityRecallDrafts {
                    Divider()
                    compatibilityRecallDraftsSection
                }

                if let recallErrorMessage { errorLabel(recallErrorMessage) }
            }
        } label: {
            topLevelSectionLabel(
                title: "Recall Card",
                summary: recallSectionSummary,
                action: .init(
                    title: recallHeaderActionTitle,
                    systemImage: "sparkles.rectangle.stack",
                    isLoading: isGeneratingRecall,
                    isDisabled: isGeneratingRecall || firstDefinition == nil,
                    handler: generateRecallDraft
                )
            )
        }
    }

    private var learningAidsSection: some View {
        DisclosureGroup(isExpanded: $isLearningAidsSectionExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                sectionDescription("Pitfalls, mnemonics, and collocations.")
                learningAidArtifactSection(
                    title: "Pitfalls",
                    suggestedRowIDs: suggestedPitfallState.rowOrder,
                    acceptedRowIDs: acceptedPitfallState.rowOrder,
                    suggestedEmptyText: "No pitfalls yet.",
                    acceptedEmptyText: "Nothing saved yet.",
                    suggestedBinding: bindingForSuggestedPitfall(rowID:),
                    acceptedBinding: bindingForAcceptedPitfall(rowID:),
                    accept: acceptSuggestedPitfall(rowID:),
                    reject: rejectSuggestedPitfall(rowID:),
                    delete: deleteAcceptedPitfall(rowID:),
                    scheduleAcceptedAutosave: scheduleAcceptedPitfallAutosave(rowID:value:)
                )
                Divider()
                learningAidArtifactSection(
                    title: "Mnemonics",
                    suggestedRowIDs: suggestedMnemonicState.rowOrder,
                    acceptedRowIDs: acceptedMnemonicState.rowOrder,
                    suggestedEmptyText: "No mnemonics yet.",
                    acceptedEmptyText: "Nothing saved yet.",
                    suggestedBinding: bindingForSuggestedMnemonic(rowID:),
                    acceptedBinding: bindingForAcceptedMnemonic(rowID:),
                    accept: acceptSuggestedMnemonic(rowID:),
                    reject: rejectSuggestedMnemonic(rowID:),
                    delete: deleteAcceptedMnemonic(rowID:),
                    scheduleAcceptedAutosave: scheduleAcceptedMnemonicAutosave(rowID:value:)
                )
                Divider()
                learningAidArtifactSection(
                    title: "Collocations",
                    suggestedRowIDs: suggestedCollocationState.rowOrder,
                    acceptedRowIDs: acceptedCollocationState.rowOrder,
                    suggestedEmptyText: "No collocations yet.",
                    acceptedEmptyText: "Nothing saved yet.",
                    suggestedBinding: bindingForSuggestedCollocation(rowID:),
                    acceptedBinding: bindingForAcceptedCollocation(rowID:),
                    accept: acceptSuggestedCollocation(rowID:),
                    reject: rejectSuggestedCollocation(rowID:),
                    delete: deleteAcceptedCollocation(rowID:),
                    scheduleAcceptedAutosave: scheduleAcceptedCollocationAutosave(rowID:value:)
                )

                if let learningAidsErrorMessage { errorLabel(learningAidsErrorMessage) }
            }
        } label: {
            topLevelSectionLabel(
                title: "Learning Aids",
                summary: learningAidsSectionSummary,
                action: .init(
                    title: isGeneratingLearningAids ? "Generating..." : learningAidsHeaderActionTitle,
                    systemImage: "wand.and.stars",
                    isLoading: isGeneratingLearningAids,
                    isDisabled: isGeneratingLearningAids || firstDefinition == nil,
                    handler: generateLearningAids
                )
            )
        }
    }

    private var compatibilityRecallDraftsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                sectionDescription("Older multi-draft records stay available here for compatibility while the UI focuses on one active draft plus one saved card.")

                if suggestedRecallState.rowOrder.count > 1 {
                    workspaceSubsectionHeader(title: "Legacy Drafts")
                    ForEach(Array(suggestedRecallState.rowOrder.dropFirst()), id: \.self) { rowID in
                        EditableRecallDraftCard(
                            draft: bindingForSuggestedRecallDraft(rowID: rowID),
                            primaryButtonTitle: "Save Recall Card",
                            secondaryButtonTitle: "Discard Draft",
                            tagText: "Legacy draft",
                            onPrimary: { saveSuggestedRecallDraft(rowID: rowID) },
                            onSecondary: { rejectSuggestedRecallDraft(rowID: rowID) }
                        )
                    }
                }

                if acceptedRecallState.rowOrder.count > 1 {
                    workspaceSubsectionHeader(title: "Legacy Saved Cards")
                    ForEach(Array(acceptedRecallState.rowOrder.dropFirst()), id: \.self) { rowID in
                        EditableRecallDraftCard(
                            draft: bindingForAcceptedRecallDraft(rowID: rowID),
                            secondaryButtonTitle: "Delete Legacy Card",
                            tagText: "Legacy saved",
                            onModeChange: { persistAcceptedRecallModeChange(rowID: rowID, value: $0) },
                            onDraftChange: { scheduleAcceptedRecallAutosave(rowID: rowID, value: $0) },
                            onSecondary: { deleteAcceptedRecallDraft(rowID: rowID) }
                        )
                    }
                }
            }
        } label: {
            subsectionHeader("Legacy Compatibility Drafts")
        }
    }

    private func generateSentences() {
        guard examplesTask == nil else { return }
        guard let result = item.lookupResult else { return }
        let contexts = exampleSenseContexts(from: result)
        let senses = contexts.map(\.promptInput)
        guard !contexts.isEmpty else { return }

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
                let examples = try await llmService.generateExampleSentenceArtifacts(
                    word: item.word,
                    senses: senses
                )
                let artifacts = normalizeExampleArtifacts(examples, contexts: contexts)
                viewModel.saveAISuggestedExampleArtifacts(artifacts, for: item)
                logger.info("Regenerate Examples finished, \(artifacts.count) lines")
            } catch {
                examplesErrorMessage = error.localizedDescription
                logger.error("Regenerate Examples failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func generateLearningAids() {
        guard learningAidsTask == nil else { return }
        guard let result = item.lookupResult else { return }
        let senses = exampleSenseContexts(from: result).map(\.promptInput)
        guard !senses.isEmpty else { return }

        learningAidsErrorMessage = nil
        logger.info("Generate Learning Aids started for \(item.word, privacy: .public)")

        learningAidsTask?.cancel()
        learningAidsTask = Task { @MainActor in
            syncGeneratingState()
            defer {
                learningAidsTask = nil
                syncGeneratingState()
            }

            do {
                let aids = try await llmService.generateLearningAids(
                    word: item.word,
                    senses: senses
                )
                viewModel.saveAISuggestedPitfalls(
                    aids.pitfalls.compactMap { pitfallText(from: $0) },
                    for: item
                )
                viewModel.saveAISuggestedMnemonics(
                    aids.mnemonics.map(\.clue),
                    for: item
                )
                viewModel.saveAISuggestedCollocations(
                    aids.collocations.map { collocationText(from: $0) },
                    for: item
                )
                isLearningAidsSectionExpanded = true
                logger.info("Generate Learning Aids finished")
            } catch {
                learningAidsErrorMessage = error.localizedDescription
                logger.error("Generate Learning Aids failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func optimizeDefinition() {
        guard usageTask == nil else { return }
        guard let result = item.lookupResult else { return }
        let senses = exampleSenseContexts(from: result).map(\.promptInput)
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
                suggestedDefinitionState.mergePersistedValue(optimized)
                logger.info("Regenerate Usage finished")
            } catch {
                usageErrorMessage = error.localizedDescription
                logger.error("Regenerate Usage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func generateRecallDraft() {
        guard recallTask == nil else { return }
        guard let result = item.lookupResult else { return }
        let senses = exampleSenseContexts(from: result).map(\.promptInput)
        guard !senses.isEmpty else { return }

        recallErrorMessage = nil
        logger.info("Generate Recall Draft started for \(item.word, privacy: .public)")

        recallTask?.cancel()
        recallTask = Task { @MainActor in
            syncGeneratingState()
            defer {
                recallTask = nil
                syncGeneratingState()
            }

            do {
                let decision = try await llmService.generateRecallCardDraftDecision(
                    word: item.word,
                    senses: senses,
                    context: recallGenerationContext,
                    allowedModes: recommendedRecallAllowedModes,
                    modePrior: recommendedRecallModePrior
                )
                let generated = decision.draft
                let draft = RecallCardDraft(
                    mode: RecallCardMode(rawValue: generated.mode.rawValue) ?? .fullSpelling,
                    front: generated.front,
                    back: generated.back,
                    hint: generated.hint
                )
                viewModel.saveAISuggestedRecallCardDrafts([draft], for: item)
                isRecallSectionExpanded = true
                logger.info("Generate Recall Draft finished")
            } catch {
                recallErrorMessage = error.localizedDescription
                logger.error("Generate Recall Draft failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func acceptSuggestedExample(rowID: UUID) {
        guard let index = suggestedExampleState.rowOrder.firstIndex(of: rowID),
              let suggested = suggestedExampleArtifacts[safe: index] else { return }
        let trimmed = (suggestedExampleState.drafts[rowID] ?? suggested.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var accepted = acceptedExampleArtifacts
        accepted.append(
            trimmed == suggested.text
                ? suggested
                : AIExampleArtifactEditor.artifact(byApplyingEditedText: trimmed, to: suggested)
        )
        viewModel.saveAIAcceptedExampleArtifacts(accepted, for: item)

        var remaining = suggestedExampleArtifacts
        remaining.remove(at: index)
        viewModel.saveAISuggestedExampleArtifacts(remaining, for: item)
    }

    private func rejectSuggestedExample(rowID: UUID) {
        guard let index = suggestedExampleState.rowOrder.firstIndex(of: rowID),
              suggestedExampleArtifacts.indices.contains(index) else { return }
        var remaining = suggestedExampleArtifacts
        remaining.remove(at: index)
        viewModel.saveAISuggestedExampleArtifacts(remaining, for: item)
    }

    private func deleteAcceptedExample(rowID: UUID) {
        guard let index = acceptedExampleState.rowOrder.firstIndex(of: rowID) else { return }
        acceptedExampleAutosaveTasks[rowID]?.cancel()
        acceptedExampleAutosaveTasks.removeValue(forKey: rowID)
        var accepted = acceptedExampleArtifacts
        accepted.remove(at: index)
        viewModel.saveAIAcceptedExampleArtifacts(accepted, for: item)
    }

    private func acceptSuggestedDefinition() {
        let trimmed = suggestedDefinitionState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.saveAIAcceptedDefinitionNote(trimmed, for: item)
        viewModel.saveAISuggestedDefinitionNote(nil, for: item)
        suggestedDefinitionState.mergePersistedValue("")
    }

    private func rejectSuggestedDefinition() {
        viewModel.saveAISuggestedDefinitionNote(nil, for: item)
        suggestedDefinitionState.mergePersistedValue("")
    }

    private func deleteAcceptedDefinition() {
        acceptedDefinitionAutosaveTask?.cancel()
        acceptedDefinitionAutosaveTask = nil
        viewModel.saveAIAcceptedDefinitionNote(nil, for: item)
        acceptedDefinitionState.mergePersistedValue("")
    }

    private func saveSuggestedRecallDraft(rowID: UUID) {
        guard let index = suggestedRecallState.rowOrder.firstIndex(of: rowID),
              let suggested = item.aiSuggestedRecallCardDrafts[safe: index] else { return }
        let draft = suggestedRecallState.drafts[rowID] ?? suggested
        viewModel.saveAIAcceptedRecallCardDrafts([draft], for: item)

        var remaining = item.aiSuggestedRecallCardDrafts
        remaining.remove(at: index)
        viewModel.saveAISuggestedRecallCardDrafts(remaining, for: item)
        isRecallSectionExpanded = true
    }

    private func rejectSuggestedRecallDraft(rowID: UUID) {
        guard let index = suggestedRecallState.rowOrder.firstIndex(of: rowID),
              item.aiSuggestedRecallCardDrafts.indices.contains(index) else { return }
        var remaining = item.aiSuggestedRecallCardDrafts
        remaining.remove(at: index)
        viewModel.saveAISuggestedRecallCardDrafts(remaining, for: item)
    }

    private func deleteAcceptedRecallDraft(rowID: UUID) {
        acceptedRecallAutosaveTasks[rowID]?.cancel()
        acceptedRecallAutosaveTasks.removeValue(forKey: rowID)
        viewModel.saveAIAcceptedRecallCardDrafts([], for: item)
    }

    private func acceptSuggestedPitfall(rowID: UUID) {
        guard let index = suggestedPitfallState.rowOrder.firstIndex(of: rowID),
              let value = item.aiSuggestedPitfalls[safe: index]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        var accepted = item.aiAcceptedPitfalls
        accepted.append(value)
        viewModel.saveAIAcceptedPitfalls(accepted, for: item)

        var remaining = item.aiSuggestedPitfalls
        remaining.remove(at: index)
        viewModel.saveAISuggestedPitfalls(remaining, for: item)
    }

    private func rejectSuggestedPitfall(rowID: UUID) {
        guard let index = suggestedPitfallState.rowOrder.firstIndex(of: rowID),
              item.aiSuggestedPitfalls.indices.contains(index) else { return }
        var remaining = item.aiSuggestedPitfalls
        remaining.remove(at: index)
        viewModel.saveAISuggestedPitfalls(remaining, for: item)
    }

    private func deleteAcceptedPitfall(rowID: UUID) {
        guard let index = acceptedPitfallState.rowOrder.firstIndex(of: rowID) else { return }
        acceptedPitfallAutosaveTasks[rowID]?.cancel()
        acceptedPitfallAutosaveTasks.removeValue(forKey: rowID)
        var values = item.aiAcceptedPitfalls
        values.remove(at: index)
        viewModel.saveAIAcceptedPitfalls(values, for: item)
    }

    private func acceptSuggestedMnemonic(rowID: UUID) {
        guard let index = suggestedMnemonicState.rowOrder.firstIndex(of: rowID) else { return }
        moveSuggestedString(
            at: index,
            suggestedValues: item.aiSuggestedMnemonics,
            acceptedValues: item.aiAcceptedMnemonics,
            saveSuggested: viewModel.saveAISuggestedMnemonics,
            saveAccepted: viewModel.saveAIAcceptedMnemonics
        )
    }

    private func rejectSuggestedMnemonic(rowID: UUID) {
        guard let index = suggestedMnemonicState.rowOrder.firstIndex(of: rowID) else { return }
        removeSuggestedString(at: index, values: item.aiSuggestedMnemonics, saveSuggested: viewModel.saveAISuggestedMnemonics)
    }

    private func deleteAcceptedMnemonic(rowID: UUID) {
        guard let index = acceptedMnemonicState.rowOrder.firstIndex(of: rowID) else { return }
        acceptedMnemonicAutosaveTasks[rowID]?.cancel()
        acceptedMnemonicAutosaveTasks.removeValue(forKey: rowID)
        var values = item.aiAcceptedMnemonics
        values.remove(at: index)
        viewModel.saveAIAcceptedMnemonics(values, for: item)
    }

    private func acceptSuggestedCollocation(rowID: UUID) {
        guard let index = suggestedCollocationState.rowOrder.firstIndex(of: rowID) else { return }
        moveSuggestedString(
            at: index,
            suggestedValues: item.aiSuggestedCollocations,
            acceptedValues: item.aiAcceptedCollocations,
            saveSuggested: viewModel.saveAISuggestedCollocations,
            saveAccepted: viewModel.saveAIAcceptedCollocations
        )
    }

    private func rejectSuggestedCollocation(rowID: UUID) {
        guard let index = suggestedCollocationState.rowOrder.firstIndex(of: rowID) else { return }
        removeSuggestedString(at: index, values: item.aiSuggestedCollocations, saveSuggested: viewModel.saveAISuggestedCollocations)
    }

    private func deleteAcceptedCollocation(rowID: UUID) {
        guard let index = acceptedCollocationState.rowOrder.firstIndex(of: rowID) else { return }
        acceptedCollocationAutosaveTasks[rowID]?.cancel()
        acceptedCollocationAutosaveTasks.removeValue(forKey: rowID)
        var values = item.aiAcceptedCollocations
        values.remove(at: index)
        viewModel.saveAIAcceptedCollocations(values, for: item)
    }

    private func syncExampleDrafts() {
        suggestedExampleState = AIDraftListSynchronizer.sync(
            persistedValues: suggestedExampleArtifacts,
            currentState: suggestedExampleState,
            draftValue: \.text
        ).state

        let acceptedResult = AIDraftListSynchronizer.sync(
            persistedValues: acceptedExampleArtifacts,
            currentState: acceptedExampleState,
            draftValue: \.text
        )
        cancelAutosaveTasks(&acceptedExampleAutosaveTasks, removedRowIDs: acceptedResult.removedRowIDs)
        acceptedExampleState = acceptedResult.state
    }

    private func syncRecallDrafts() {
        suggestedRecallState = AIDraftListSynchronizer.sync(
            persistedValues: item.aiSuggestedRecallCardDrafts,
            currentState: suggestedRecallState,
            draftValue: { $0 }
        ).state

        let acceptedResult = AIDraftListSynchronizer.sync(
            persistedValues: item.aiAcceptedRecallCardDrafts,
            currentState: acceptedRecallState,
            draftValue: { $0 }
        )
        cancelAutosaveTasks(&acceptedRecallAutosaveTasks, removedRowIDs: acceptedResult.removedRowIDs)
        acceptedRecallState = acceptedResult.state
    }

    private func consumeAcceptedRecallPersistedEchoIfNeeded() -> Bool {
        guard let pending = pendingAcceptedRecallPersistedEcho else { return false }
        guard item.aiAcceptedRecallCardDrafts == [pending],
              let rowID = acceptedRecallState.rowOrder.first else {
            pendingAcceptedRecallPersistedEcho = nil
            return false
        }

        acceptedRecallState.persistedByRowID[rowID] = pending
        acceptedRecallState.drafts[rowID] = pending
        pendingAcceptedRecallPersistedEcho = nil
        return true
    }

    private func syncPitfallDrafts() {
        suggestedPitfallState = AIDraftListSynchronizer.sync(
            persistedValues: item.aiSuggestedPitfalls,
            currentState: suggestedPitfallState,
            draftValue: { $0 }
        ).state

        let acceptedResult = AIDraftListSynchronizer.sync(
            persistedValues: item.aiAcceptedPitfalls,
            currentState: acceptedPitfallState,
            draftValue: { $0 }
        )
        cancelAutosaveTasks(&acceptedPitfallAutosaveTasks, removedRowIDs: acceptedResult.removedRowIDs)
        acceptedPitfallState = acceptedResult.state
    }

    private func syncMnemonicDrafts() {
        suggestedMnemonicState = AIDraftListSynchronizer.sync(
            persistedValues: item.aiSuggestedMnemonics,
            currentState: suggestedMnemonicState,
            draftValue: { $0 }
        ).state

        let acceptedResult = AIDraftListSynchronizer.sync(
            persistedValues: item.aiAcceptedMnemonics,
            currentState: acceptedMnemonicState,
            draftValue: { $0 }
        )
        cancelAutosaveTasks(&acceptedMnemonicAutosaveTasks, removedRowIDs: acceptedResult.removedRowIDs)
        acceptedMnemonicState = acceptedResult.state
    }

    private func syncCollocationDrafts() {
        suggestedCollocationState = AIDraftListSynchronizer.sync(
            persistedValues: item.aiSuggestedCollocations,
            currentState: suggestedCollocationState,
            draftValue: { $0 }
        ).state

        let acceptedResult = AIDraftListSynchronizer.sync(
            persistedValues: item.aiAcceptedCollocations,
            currentState: acceptedCollocationState,
            draftValue: { $0 }
        )
        cancelAutosaveTasks(&acceptedCollocationAutosaveTasks, removedRowIDs: acceptedResult.removedRowIDs)
        acceptedCollocationState = acceptedResult.state
    }

    private func bindingForSuggestedDefinition() -> Binding<String> {
        Binding(
            get: { suggestedDefinitionState.draft },
            set: { suggestedDefinitionState.updateDraft($0) }
        )
    }

    private func bindingForAcceptedDefinition() -> Binding<String> {
        Binding(
            get: { acceptedDefinitionState.draft },
            set: { acceptedDefinitionState.updateDraft($0) }
        )
    }

    private func bindingForSuggestedExample(rowID: UUID) -> Binding<String> {
        Binding(
            get: { suggestedExampleState.drafts[rowID] ?? suggestedExampleState.persistedByRowID[rowID]?.text ?? "" },
            set: { suggestedExampleState.drafts[rowID] = $0 }
        )
    }

    private func bindingForAcceptedExample(rowID: UUID) -> Binding<String> {
        Binding(
            get: { acceptedExampleState.drafts[rowID] ?? acceptedExampleState.persistedByRowID[rowID]?.text ?? "" },
            set: { acceptedExampleState.drafts[rowID] = $0 }
        )
    }

    private func bindingForSuggestedRecallDraft(rowID: UUID) -> Binding<RecallCardDraft> {
        Binding(
            get: {
                suggestedRecallState.drafts[rowID]
                    ?? suggestedRecallState.persistedByRowID[rowID]
                    ?? RecallCardDraft(mode: .phraseRecall, front: "", back: "")
            },
            set: { suggestedRecallState.drafts[rowID] = $0 }
        )
    }

    private func bindingForAcceptedRecallDraft(rowID: UUID) -> Binding<RecallCardDraft> {
        Binding(
            get: {
                acceptedRecallState.drafts[rowID]
                    ?? acceptedRecallState.persistedByRowID[rowID]
                    ?? RecallCardDraft(mode: .phraseRecall, front: "", back: "")
            },
            set: { acceptedRecallState.drafts[rowID] = $0 }
        )
    }

    private func bindingForSuggestedPitfall(rowID: UUID) -> Binding<String> {
        Binding(
            get: { suggestedPitfallState.drafts[rowID] ?? suggestedPitfallState.persistedByRowID[rowID] ?? "" },
            set: { suggestedPitfallState.drafts[rowID] = $0 }
        )
    }

    private func bindingForAcceptedPitfall(rowID: UUID) -> Binding<String> {
        Binding(
            get: { acceptedPitfallState.drafts[rowID] ?? acceptedPitfallState.persistedByRowID[rowID] ?? "" },
            set: { acceptedPitfallState.drafts[rowID] = $0 }
        )
    }

    private func bindingForSuggestedMnemonic(rowID: UUID) -> Binding<String> {
        Binding(
            get: { suggestedMnemonicState.drafts[rowID] ?? suggestedMnemonicState.persistedByRowID[rowID] ?? "" },
            set: { suggestedMnemonicState.drafts[rowID] = $0 }
        )
    }

    private func bindingForAcceptedMnemonic(rowID: UUID) -> Binding<String> {
        Binding(
            get: { acceptedMnemonicState.drafts[rowID] ?? acceptedMnemonicState.persistedByRowID[rowID] ?? "" },
            set: { acceptedMnemonicState.drafts[rowID] = $0 }
        )
    }

    private func bindingForSuggestedCollocation(rowID: UUID) -> Binding<String> {
        Binding(
            get: { suggestedCollocationState.drafts[rowID] ?? suggestedCollocationState.persistedByRowID[rowID] ?? "" },
            set: { suggestedCollocationState.drafts[rowID] = $0 }
        )
    }

    private func bindingForAcceptedCollocation(rowID: UUID) -> Binding<String> {
        Binding(
            get: { acceptedCollocationState.drafts[rowID] ?? acceptedCollocationState.persistedByRowID[rowID] ?? "" },
            set: { acceptedCollocationState.drafts[rowID] = $0 }
        )
    }

    private func scheduleAcceptedExampleAutosave(rowID: UUID, value: String) {
        acceptedExampleAutosaveTasks[rowID]?.cancel()
        acceptedExampleAutosaveTasks[rowID] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let index = acceptedExampleState.rowOrder.firstIndex(of: rowID),
                  let current = acceptedExampleArtifacts[safe: index] else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != current.text else { return }
            var accepted = acceptedExampleArtifacts
            accepted[index] = AIExampleArtifactEditor.artifact(byApplyingEditedText: trimmed, to: current)
            viewModel.saveAIAcceptedExampleArtifacts(accepted, for: item)
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

    private func scheduleAcceptedRecallAutosave(rowID: UUID, value: RecallCardDraft) {
        acceptedRecallAutosaveTasks[rowID]?.cancel()
        acceptedRecallAutosaveTasks[rowID] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard item.aiAcceptedRecallCardDrafts.first != value else { return }
            pendingAcceptedRecallPersistedEcho = value
            viewModel.saveAIAcceptedRecallCardDrafts([value], for: item)
        }
    }

    private func persistAcceptedRecallModeChange(rowID: UUID, value: RecallCardDraft) {
        acceptedRecallAutosaveTasks[rowID]?.cancel()
        acceptedRecallAutosaveTasks.removeValue(forKey: rowID)
        guard item.aiAcceptedRecallCardDrafts.first != value else { return }
        pendingAcceptedRecallPersistedEcho = value
        viewModel.saveAIAcceptedRecallCardDrafts([value], for: item)
    }

    private func scheduleAcceptedPitfallAutosave(rowID: UUID, value: String) {
        acceptedPitfallAutosaveTasks[rowID]?.cancel()
        acceptedPitfallAutosaveTasks[rowID] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let index = acceptedPitfallState.rowOrder.firstIndex(of: rowID) else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != item.aiAcceptedPitfalls[safe: index] else { return }
            var values = item.aiAcceptedPitfalls
            values[index] = trimmed
            viewModel.saveAIAcceptedPitfalls(values, for: item)
        }
    }

    private func scheduleAcceptedMnemonicAutosave(rowID: UUID, value: String) {
        acceptedMnemonicAutosaveTasks[rowID]?.cancel()
        acceptedMnemonicAutosaveTasks[rowID] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let index = acceptedMnemonicState.rowOrder.firstIndex(of: rowID) else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != item.aiAcceptedMnemonics[safe: index] else { return }
            var values = item.aiAcceptedMnemonics
            values[index] = trimmed
            viewModel.saveAIAcceptedMnemonics(values, for: item)
        }
    }

    private func scheduleAcceptedCollocationAutosave(rowID: UUID, value: String) {
        acceptedCollocationAutosaveTasks[rowID]?.cancel()
        acceptedCollocationAutosaveTasks[rowID] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let index = acceptedCollocationState.rowOrder.firstIndex(of: rowID) else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != item.aiAcceptedCollocations[safe: index] else { return }
            var values = item.aiAcceptedCollocations
            values[index] = trimmed
            viewModel.saveAIAcceptedCollocations(values, for: item)
        }
    }

    private func cancelAutosaveTasks(
        _ tasks: inout [UUID: Task<Void, Never>],
        removedRowIDs: [UUID]
    ) {
        for rowID in removedRowIDs {
            tasks[rowID]?.cancel()
            tasks.removeValue(forKey: rowID)
        }
    }

    private func syncGeneratingState() {
        item.isGeneratingAI = isGeneratingExamples || isGeneratingLearningAids || isGeneratingUsage || isGeneratingRecall
    }

    private var firstDefinition: String? {
        guard let result = item.lookupResult else { return nil }
        return exampleSenseContexts(from: result).first?.definition
    }

    private func exampleSenseContexts(from result: LookupResult) -> [ExampleSenseContext] {
        var seen = Set<String>()
        var contexts: [ExampleSenseContext] = []

        for entry in result.entries {
            for (lexicalEntryIndex, lexical) in entry.lexicalEntries.enumerated() {
                for (senseIndex, sense) in lexical.senses.enumerated() {
                    let trimmedDefinition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedDefinition.isEmpty else { continue }

                    let context = ExampleSenseContext(
                        partOfSpeech: lexical.partOfSpeechLabel,
                        definition: trimmedDefinition,
                        semanticHint: sense.semanticHint,
                        anchor: AIArtifactAnchorSnapshot(
                            headword: entry.headword,
                            lexicalEntryIndex: lexicalEntryIndex,
                            senseIndex: senseIndex,
                            exampleIndex: nil,
                            excerpt: sense.semanticHint ?? trimmedDefinition
                        )
                    )
                    let key = [
                        context.partOfSpeech.lowercased(),
                        context.definition.lowercased(),
                        (context.semanticHint ?? "").lowercased()
                    ].joined(separator: "|")
                    guard seen.insert(key).inserted else { continue }
                    contexts.append(context)
                }
            }
        }

        return contexts
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

    private func learningAidArtifactSection(
        title: String,
        suggestedRowIDs: [UUID],
        acceptedRowIDs: [UUID],
        suggestedEmptyText: String,
        acceptedEmptyText: String,
        suggestedBinding: @escaping (UUID) -> Binding<String>,
        acceptedBinding: @escaping (UUID) -> Binding<String>,
        accept: @escaping (UUID) -> Void,
        reject: @escaping (UUID) -> Void,
        delete: @escaping (UUID) -> Void,
        scheduleAcceptedAutosave: @escaping (UUID, String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            subsectionHeader(title)
            if !suggestedRowIDs.isEmpty {
                sectionSubheader("Suggestions")
                ForEach(suggestedRowIDs, id: \.self) { rowID in
                    EditableAITextCard(
                        text: suggestedBinding(rowID),
                        primaryButtonTitle: "Save",
                        secondaryButtonTitle: "Dismiss",
                        onPrimary: { accept(rowID) },
                        onSecondary: { reject(rowID) }
                    )
                }
            } else {
                emptyState(suggestedEmptyText)
            }
            if !acceptedRowIDs.isEmpty {
                sectionSubheader("Saved").padding(.top, 2)
                ForEach(acceptedRowIDs, id: \.self) { rowID in
                    EditableAITextCard(
                        text: acceptedBinding(rowID),
                        secondaryButtonTitle: "Delete",
                        tagText: "Saved",
                        onTextChange: { scheduleAcceptedAutosave(rowID, $0) },
                        onSecondary: { delete(rowID) }
                    )
                }
            } else {
                emptyState(acceptedEmptyText)
            }
        }
    }

    private func normalizeExampleArtifacts(
        _ examples: [LLMExampleSentence],
        contexts: [ExampleSenseContext]
    ) -> [ExampleSentenceArtifact] {
        examples.compactMap { example in
            let english = example.english.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = example.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, !translation.isEmpty else { return nil }

            let anchor = resolvedExampleSenseContext(
                forSenseIndex: example.senseIndex,
                contexts: contexts
            )?.anchor

            return ExampleSentenceArtifact(
                text: "\(english) — \(translation)",
                translation: translation,
                anchor: anchor
            )
        }
    }

    private func resolvedExampleSenseContext(
        forSenseIndex senseIndex: Int?,
        contexts: [ExampleSenseContext]
    ) -> ExampleSenseContext? {
        if let senseIndex, contexts.indices.contains(senseIndex - 1) {
            return contexts[senseIndex - 1]
        }
        if contexts.count == 1 {
            return contexts[0]
        }
        return nil
    }

    private func exampleSenseContext(for anchor: AIArtifactAnchorSnapshot?) -> ExampleSenseContext? {
        guard let anchor else { return nil }
        return currentExampleSenseContexts.first {
            $0.anchor.lexicalEntryIndex == anchor.lexicalEntryIndex &&
                $0.anchor.senseIndex == anchor.senseIndex &&
                $0.anchor.headword == anchor.headword
        }
    }

    private func exampleTagText(
        for artifact: ExampleSentenceArtifact,
        among artifacts: [ExampleSentenceArtifact]
    ) -> String? {
        guard let context = exampleSenseContext(for: artifact.anchor) else { return nil }

        let contextsForSamePartOfSpeech = artifacts.compactMap { candidate in
            exampleSenseContext(for: candidate.anchor)
        }
        .filter {
            $0.partOfSpeech.caseInsensitiveCompare(context.partOfSpeech) == .orderedSame
        }

        let distinctSenseKeys = Set(contextsForSamePartOfSpeech.map(\.key))
        guard distinctSenseKeys.count > 1 else {
            return shortPartOfSpeechLabel(context.partOfSpeech)
        }

        return shortPartOfSpeechLabel(context.partOfSpeech)
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
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.06), lineWidth: 1))
    }

    private func topLevelSectionLabel(title: String, summary: String, action: SectionHeaderAction? = nil) -> some View {
        ViewThatFits(in: .horizontal) {
            headerRow(
                title: title,
                summary: summary,
                trailing: action.map { action in
                    AnyView(
                        Button(action: action.handler) {
                            actionButtonLabel(
                                title: action.title,
                                systemImage: action.systemImage,
                                isLoading: action.isLoading
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(action.isDisabled)
                    )
                }
            )

            headerRow(
                title: title,
                summary: summary,
                trailing: action.map { action in
                    AnyView(
                        Button(action: action.handler) {
                            compactActionButtonLabel(
                                systemImage: action.systemImage,
                                isLoading: action.isLoading
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(action.title)
                        .disabled(action.isDisabled)
                    )
                }
            )

            headerRow(title: title, summary: summary)
        }
        .padding(.vertical, 2)
    }

    private func headerRow(title: String, summary: String, trailing: AnyView? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)

            SectionSummaryBadge(text: summary)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)

            if let trailing {
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortPartOfSpeechLabel(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.lowercased() {
        case "adjective":
            return "adj."
        case "adverb":
            return "adv."
        case "noun":
            return "noun"
        case "verb":
            return "verb"
        default:
            return normalized.count > 12 ? String(normalized.prefix(12)) : normalized
        }
    }

    private func pitfallText(from pitfall: LLMPitfall) -> String {
        [pitfall.summary, pitfall.details]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func collocationText(from collocation: LLMCollocation) -> String {
        let phrase = collocation.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let gloss = collocation.gloss?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gloss, !gloss.isEmpty else { return phrase }
        return "\(phrase) — \(gloss)"
    }

    private var learningAidsHeaderActionTitle: String {
        let hasSuggestions = !suggestedPitfallState.rowOrder.isEmpty ||
            !suggestedMnemonicState.rowOrder.isEmpty ||
            !suggestedCollocationState.rowOrder.isEmpty
        return (hasSuggestions || hasAcceptedLearningAids) ? "Regenerate" : "Generate"
    }

    private var recallHeaderActionTitle: String {
        if primarySuggestedRecallDraftRowID != nil || primaryAcceptedRecallDraftRowID != nil || hasCompatibilityRecallDrafts {
            return "New Draft"
        }
        return "Generate Draft"
    }

    private var recallGenerationContext: LLMRecallGenerationContext {
        LLMService.normalizeRecallGenerationContext(
            LLMRecallGenerationContext(
                acceptedPitfalls: item.aiAcceptedPitfalls,
                acceptedUsageHints: acceptedUsageHints(from: item.aiAcceptedDefinitionNote),
                acceptedMnemonics: item.aiAcceptedMnemonics,
                acceptedCollocations: item.aiAcceptedCollocations
            )
        )
    }

    private var recommendedRecallAllowedModes: [LLMRecallCardMode] {
        LLMService.recommendedRecallAllowedModes(
            for: item.word,
            context: recallGenerationContext
        )
    }

    private var recommendedRecallModePrior: LLMRecallCardMode? {
        LLMService.recommendedRecallModePrior(
            for: item.word,
            context: recallGenerationContext,
            allowedModes: recommendedRecallAllowedModes
        )
    }

    private func acceptedUsageHints(from note: String?) -> [String] {
        guard let note else { return [] }
        return note
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func sectionHeader(title: String) -> some View {
        Text(title).font(.headline.weight(.semibold))
    }

    private func subsectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
    }

    private func workspaceSubsectionHeader(title: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            subsectionHeader(title)
            if let caption {
                sectionDescription(caption)
            }
        }
    }

    private func sectionSubheader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.05), in: Capsule())
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func sectionDescription(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
    }

    private func generatingState(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func errorLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.red)
    }

    private func sectionSummary(savedCount: Int, suggestedCount: Int, isGenerating: Bool) -> String {
        if savedCount > 0 {
            return savedCount == 1 ? "1 saved" : "\(savedCount) saved"
        }
        if suggestedCount > 0 {
            return suggestedCount == 1 ? "1 suggestion" : "\(suggestedCount) suggestions"
        }
        if isGenerating {
            return "generating"
        }
        return "empty"
    }

    private func countSummary(_ count: Int, singular: String) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? singular : "\(singular)s"
        return "\(count) \(noun)"
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
    let editorHeight: CGFloat
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
        editorHeight: CGFloat = 72,
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
        self.editorHeight = editorHeight
        self.onTextChange = onTextChange
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let tagText {
                    HStack(spacing: 0) {
                        AIArtifactTag(text: tagText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }

                TextEditor(text: $text)
                    .frame(height: editorHeight)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.top, tagText == nil ? 8 : 0)
                    .padding(.bottom, 8)
                    .onChange(of: text) { newValue in onTextChange?(newValue) }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.08))
            )

            HStack(spacing: 8) {
                if let primaryButtonTitle {
                    Button(role: primaryRole, action: onPrimary) { Text(primaryButtonTitle) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button(role: secondaryRole, action: onSecondary) { Text(secondaryButtonTitle) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.05), lineWidth: 1))
    }
}

private struct EditableRecallDraftCard: View {
    fileprivate enum FocusField: Hashable {
        case front
        case back
        case hint
    }

    @Binding var draft: RecallCardDraft
    @State private var selectedMode: RecallCardMode
    @FocusState private var focusedField: FocusField?

    let primaryButtonTitle: String?
    let secondaryButtonTitle: String
    let tagText: String?
    let onModeChange: ((RecallCardDraft) -> Void)?
    let onDraftChange: ((RecallCardDraft) -> Void)?
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    init(
        draft: Binding<RecallCardDraft>,
        primaryButtonTitle: String? = nil,
        secondaryButtonTitle: String,
        tagText: String? = nil,
        onModeChange: ((RecallCardDraft) -> Void)? = nil,
        onDraftChange: ((RecallCardDraft) -> Void)? = nil,
        onPrimary: @escaping () -> Void = {},
        onSecondary: @escaping () -> Void
    ) {
        _draft = draft
        _selectedMode = State(initialValue: draft.wrappedValue.mode)
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryButtonTitle = secondaryButtonTitle
        self.tagText = tagText
        self.onModeChange = onModeChange
        self.onDraftChange = onDraftChange
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modePicker
            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            RecallDraftEditorField(
                title: "Front",
                prompt: frontPrompt,
                text: Binding(
                    get: { draft.front },
                    set: { applyUpdate(.front($0)) }
                ),
                minHeight: 78,
                focusedField: $focusedField,
                field: EditableRecallDraftCard.FocusField.front
            )

            RecallDraftEditorField(
                title: "Back",
                prompt: "Put the canonical answer here.",
                text: Binding(
                    get: { draft.back },
                    set: { applyUpdate(.back($0)) }
                ),
                minHeight: 64,
                focusedField: $focusedField,
                field: EditableRecallDraftCard.FocusField.back
            )

            RecallDraftEditorField(
                title: "Hint",
                prompt: "Optional: give the learner a small nudge, not the full answer.",
                text: Binding(
                    get: { draft.hint ?? "" },
                    set: { next in
                        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                        applyUpdate(.hint(trimmed.isEmpty ? nil : trimmed))
                    }
                ),
                minHeight: 58,
                focusedField: $focusedField,
                field: EditableRecallDraftCard.FocusField.hint
            )

            HStack(spacing: 8) {
                if let primaryButtonTitle {
                    Button(action: onPrimary) { Text(primaryButtonTitle) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button(role: .destructive, action: onSecondary) { Text(secondaryButtonTitle) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.05), lineWidth: 1))
        .onChange(of: draft.mode) { next in
            if selectedMode != next {
                selectedMode = next
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.mode.displayName)
                    .font(.headline)
                Text("Edit this like a real study card, not a raw data row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let tagText {
                AIArtifactTag(text: tagText)
            }
        }
    }

    private var modePicker: some View {
        RecallModeSegmentedControl(selection: modeSelection)
            .frame(height: 26)
    }

    private var modeSelection: Binding<RecallCardMode> {
        Binding(
            get: { selectedMode },
            set: { next in
                guard selectedMode != next else { return }
                focusedField = nil
                applyUpdate(.mode(next))
            }
        )
    }

    private func applyUpdate(_ update: RecallDraftEditorUpdate) {
        let nextDraft = RecallDraftEditorReducer.applying(
            update,
            to: draft,
            selectedMode: selectedMode
        )
        selectedMode = nextDraft.mode
        draft = nextDraft
        if update.mode != nil {
            onModeChange?(draft)
        }
        onDraftChange?(draft)
    }

    private var modeDescription: String {
        switch selectedMode {
        case .fullSpelling:
            return "Use a short cue that makes the learner recall the complete spelling."
        case .targetedLetterCloze:
            return "Keep the prompt focused on one missing segment so the learner knows what to repair."
        case .phraseRecall:
            return "Use a natural sentence cue and leave only the target word for retrieval."
        }
    }

    private var frontPrompt: String {
        switch selectedMode {
        case .fullSpelling:
            return "Example: start from a meaning cue or partial scaffold instead of copying the answer."
        case .targetedLetterCloze:
            return "Example: leave one clear blank such as le__atize, not a wall of text."
        case .phraseRecall:
            return "Example: use a short sentence with one obvious blank."
        }
    }

}

private struct RecallModeSegmentedControl: NSViewRepresentable {
    let selection: Binding<RecallCardMode>

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: selection)
    }

    func makeNSView(context: Context) -> FirstClickSegmentedControl {
        let control = FirstClickSegmentedControl(labels: RecallCardMode.allCases.map(\.displayName), trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.selectionDidChange(_:)))
        control.segmentStyle = .rounded
        control.controlSize = .regular
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateSelection(on: control)
        return control
    }

    func updateNSView(_ nsView: FirstClickSegmentedControl, context: Context) {
        context.coordinator.selection = selection
        if nsView.segmentCount != RecallCardMode.allCases.count {
            nsView.segmentCount = RecallCardMode.allCases.count
            for (index, mode) in RecallCardMode.allCases.enumerated() {
                nsView.setLabel(mode.displayName, forSegment: index)
            }
        }
        updateSelection(on: nsView)
    }

    private func updateSelection(on control: NSSegmentedControl) {
        if let index = RecallCardMode.allCases.firstIndex(of: selection.wrappedValue) {
            control.selectedSegment = index
        } else {
            control.selectedSegment = -1
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<RecallCardMode>

        init(selection: Binding<RecallCardMode>) {
            self.selection = selection
        }

        @objc func selectionDidChange(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard RecallCardMode.allCases.indices.contains(index) else { return }
            selection.wrappedValue = RecallCardMode.allCases[index]
        }
    }
}

private final class FirstClickSegmentedControl: NSSegmentedControl {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(nil)
        super.mouseDown(with: event)
    }
}

private struct RecallDraftEditorField: View {
    typealias FocusField = EditableRecallDraftCard.FocusField

    let title: String
    let prompt: String
    @Binding var text: String
    let minHeight: CGFloat
    let focusedField: FocusState<FocusField?>.Binding
    let field: FocusField

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.08))

                if text.isEmpty {
                    Text(prompt)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }

                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused(focusedField, equals: field)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minHeight: minHeight)
            }
            .frame(minHeight: minHeight)
        }
    }
}

private struct AIArtifactTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tagTint, in: Capsule())
    }

    private var tagTint: Color {
        let normalized = text.lowercased()
        if normalized.contains("noun") {
            return .blue
        }
        if normalized.contains("verb") {
            return .orange
        }
        if normalized.contains("adjective") {
            return .green
        }
        if normalized.contains("adverb") {
            return .teal
        }
        return .secondary
    }
}

private struct SectionSummaryBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
