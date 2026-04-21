import AnkiMateLLM
import AppKit
import DictKit
import DictKitAnkiExport
import SwiftUI
import WebKit

struct CardPreviewView: View {
    private static let generateIPATint = Color.blue.opacity(0.9)

    @ObservedObject var item: WordItem
    @EnvironmentObject var llmService: LLMService
    @EnvironmentObject var viewModel: WordListViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showBack: Bool = true
    @State private var previewFamily: PreviewFamily = .standard
    @AppStorage("cardPreview.aiPanelRatio") private var aiPanelRatio: Double = 0.38
    @State private var aiPanelHeight: CGFloat = 320
    @State private var isGeneratingRecallPreviewDraft = false
    @State private var recallPreviewFeedback: String?
    @State private var recallPreviewErrorMessage: String?
    @State private var generatingPronunciationDialects = Set<String>()
    @State private var pronunciationEnhancementErrorMessage: String?
    @State private var attemptedAutomaticPronunciationDialects = Set<String>()
    @State private var unavailableAlertContent: LLMGenerationAvailability.AlertContent?
    @State private var agentSession: AgentSession?
    @State private var agentPreviewOverrideArtifacts: AIArtifacts?

    private let minAIPanelHeight: CGFloat = 180
    private let minPreviewHeight: CGFloat = 96
    private var generationAvailabilityState: LLMGenerationAvailability.State {
        LLMGenerationAvailability.resolvedState(
            hasModel: llmService.hasModel,
            serverState: llmService.serverState
        )
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    let phonetics = item.phoneticsByDialect.sorted {
                        let order = ["AmE": 0, "BrE": 1]
                        return (order[$0.dialect] ?? 2) < (order[$1.dialect] ?? 2)
                    }

                    if geometry.size.width >= 920 {
                        HStack(alignment: .top, spacing: 16) {
                            pronunciationSummary(phonetics: phonetics)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            previewControls
                                .fixedSize()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 12) {
                                    pronunciationHeader
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    previewControls
                                        .fixedSize()
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    pronunciationHeader
                                    HStack {
                                        Spacer(minLength: 0)
                                        previewControls
                                            .fixedSize()
                                    }
                                }
                            }

                            pronunciationDetails(phonetics: phonetics)
                        }
                    }

                    if let pronunciationEnhancementErrorMessage {
                        Text(pronunciationEnhancementErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .task(id: pronunciationAutoGenerationTaskKey) {
                    triggerAutomaticPronunciationEnhancementIfNeeded()
                }
                .onChange(of: item.id) { _ in
                    attemptedAutomaticPronunciationDialects = []
                    pronunciationEnhancementErrorMessage = nil
                }

                Divider()
                contentArea
            }
            .onAppear {
                configureAgentSession()
            }
            .onChange(of: item.id) { _ in
                agentPreviewOverrideArtifacts = nil
                configureAgentSession()
            }
            .onChange(of: previewFamily) { _ in
                configureAgentSession()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .alert(item: $unavailableAlertContent) { content in
            Alert(
                title: Text(content.title),
                message: Text(content.message),
                primaryButton: .default(Text(content.settingsButtonTitle)) {
                    openWindow(id: AppWindowIDs.aiSettings)
                },
                secondaryButton: .cancel(Text("Cancel"))
            )
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if item.isReady {
            GeometryReader { geometry in
                CardPreviewSplitView(
                    desiredBottomHeight: aiPanelHeight,
                    availableHeight: geometry.size.height,
                    minBottomHeight: minAIPanelHeight,
                    minTopHeight: minPreviewHeight,
                    persistedRatio: aiPanelRatio,
                    onBottomHeightCommit: { height in
                        aiPanelHeight = height
                        aiPanelRatio = CardPreviewAIPanelLayout.persistedRatio(
                            forHeight: height,
                            availableHeight: geometry.size.height
                        )
                    },
                    topContent: previewContent,
                    bottomContent: AIContentView(
                        item: item,
                        agentSession: agentSession,
                        agentPreviewOverrideArtifacts: $agentPreviewOverrideArtifacts
                    )
                    .id(item.id)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                )
                .onAppear {
                    syncAIPanelHeight(availableHeight: geometry.size.height)
                }
                .onChange(of: geometry.size.height) { newHeight in
                    syncAIPanelHeight(availableHeight: newHeight)
                }
            }
        } else {
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch previewFamily {
        case .standard:
            standardPreview
        case .recall:
            recallPreview
        }
    }

    private func syncAIPanelHeight(availableHeight: CGFloat) {
        aiPanelHeight = CardPreviewAIPanelLayout.restoredHeight(
            fromPersistedRatio: aiPanelRatio,
            availableHeight: availableHeight,
            minHeight: minAIPanelHeight,
            minTopHeight: minPreviewHeight
        )
    }

    @ViewBuilder
    private func pronunciationSummary(
        phonetics: [(dialect: String, notation: String, usesIPADelimiters: Bool, pronunciation: Pronunciation)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            pronunciationHeader
            pronunciationDetails(phonetics: phonetics)
        }
    }

    private var pronunciationHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.word)
                    .font(.title2.bold())

                if item.isReady {
                    Button(action: { viewModel.retryLookup(item) }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Refresh entry from the current dictionary")
                }
            }

            if let sourceDescription = item.sourceDescription {
                Text(sourceDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let inflectionDescription = item.inflectionDescription {
                Text(inflectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func pronunciationDetails(
        phonetics: [(dialect: String, notation: String, usesIPADelimiters: Bool, pronunciation: Pronunciation)]
    ) -> some View {
        if !phonetics.isEmpty {
            let sharedStressRefreshTarget = preferredStressRefreshTarget(from: phonetics)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 14) {
                        ForEach(Array(phonetics.enumerated()), id: \.offset) { _, entry in
                            pronunciationEntry(entry)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(phonetics.enumerated()), id: \.offset) { _, entry in
                            pronunciationEntry(entry)
                        }
                    }
                }

                if let sharedStressSyllables = item.preferredGeneratedStressSyllables {
                    HStack(alignment: .center, spacing: 6) {
                        Text("Stress")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(sharedStressSyllables)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .help("Stress syllables")

                        if let target = sharedStressRefreshTarget {
                            let dialectKey = item.dialectStorageKey(for: target.dialect)
                            pronunciationIconButton(
                                systemImage: "arrow.clockwise",
                                help: pronunciationActionHelpText(defaultText: "Regenerate stress syllables"),
                                tint: Self.generateIPATint,
                                isLoading: generatingPronunciationDialects.contains(dialectKey),
                                disabled: !item.isReady || generatingPronunciationDialects.contains(dialectKey) || isActionBlocked(for: .pronunciationEnhancement)
                            ) {
                                generatePronunciationEnhancement(
                                    for: target.dialect,
                                    guide: target.guide,
                                    existingIPA: target.existingIPA
                                )
                            }
                        }
                    }
                }
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                let defaultDialectKey = item.dialectStorageKey(for: "AmE")
                let generatedIPA = item.preferredGeneratedIPA
                let generatedStressSyllables = item.generatedStressSyllables(for: "AmE")

                if let generatedIPA {
                    Text("/\(generatedIPA)/")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                }

                if let generatedStressSyllables {
                    Text("Stress")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(generatedStressSyllables)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                pronunciationActionGroup(
                    isGenerating: generatingPronunciationDialects.contains(defaultDialectKey),
                    canRefresh: item.isReady,
                    canPlay: item.isReady,
                    refreshHelp: "Generate pronunciation aid",
                    onRefresh: {
                        generatePronunciationEnhancement(
                            for: "AmE",
                            guide: nil,
                            existingIPA: generatedIPA
                        )
                    },
                    onPlay: {
                        Task { await viewModel.playPronunciation(for: item) }
                    }
                )
            }
        }
    }

    private var previewControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("", selection: $previewFamily) {
                Text("Standard").tag(PreviewFamily.standard)
                Text("Recall").tag(PreviewFamily.recall)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 168)

            Picker("", selection: $showBack) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 126)
        }
    }

    private func pronunciationEntry(
        _ entry: (dialect: String, notation: String, usesIPADelimiters: Bool, pronunciation: Pronunciation)
    ) -> some View {
        let dialectKey = item.dialectStorageKey(for: entry.dialect)
        let generatedIPA = item.generatedIPANotationsByDialect[dialectKey]

        return HStack(alignment: .center, spacing: 4) {
            if !entry.dialect.isEmpty {
                Text(entry.dialect)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(entry.dialect == "BrE" ? Color.blue : Color.orange)
                    )
                    .fixedSize()
            }

            if let generatedIPA {
                Text("/\(generatedIPA)/")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .help("Generated IPA pronunciation")
            } else {
                Text(entry.usesIPADelimiters ? "/\(entry.notation)/" : entry.notation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .help(entry.usesIPADelimiters ? "IPA pronunciation" : "Dictionary pronunciation guide")
            }

            pronunciationActionGroup(
                isGenerating: generatingPronunciationDialects.contains(dialectKey),
                canRefresh: true,
                canPlay: item.isReady,
                refreshHelp: "Generate pronunciation aid",
                onRefresh: {
                    generatePronunciationEnhancement(
                        for: entry.dialect,
                        guide: entry.notation,
                        existingIPA: entry.usesIPADelimiters ? entry.notation : generatedIPA
                    )
                },
                onPlay: {
                    Task { await viewModel.playPronunciation(for: item, pronunciation: entry.pronunciation) }
                }
            )
        }
    }

    private var standardPreview: some View {
        Group {
            if let result = item.lookupResult {
                let previewArtifacts = activePreviewArtifacts
                let note = AnkiNoteData(
                    word: item.word,
                    phonetic: AnkiFieldFormatter.phoneticDisplay(
                        from: result,
                        aiArtifacts: previewArtifacts
                    ),
                    definitions: AnkiFieldFormatter.definitionsHTML(
                        from: result,
                        aiArtifacts: previewArtifacts
                    ),
                    audioFilename: nil,
                    audioData: nil
                )
                VStack(spacing: 0) {
                    previewBanner
                    AnkiCardWebView(html: AnkiFieldFormatter.renderCardHTML(note: note, showBack: showBack))
                }
            } else if case .loading = item.lookupState {
                loadingView(text: "Looking up...")
            } else if case .failed(let msg) = item.lookupState {
                failureView(message: msg)
            } else {
                loadingView(text: "Pending...")
            }
        }
    }

    private var recallPreview: some View {
        Group {
            if let draft = previewRecallDraft, let result = item.lookupResult {
                let previewArtifacts = activePreviewArtifacts
                let note = AnkiNoteData(
                    recallPrompt: escapeHTMLPreservingLineBreaks(draft.front),
                    recallMode: escapeHTML(draft.mode.displayName),
                    recallInstruction: escapeHTML(recallInstruction(for: draft.mode)),
                    recallHint: draft.hint.map { escapeHTMLPreservingLineBreaks($0) } ?? "",
                    recallAnswerHTML: escapeHTMLPreservingLineBreaks(draft.back),
                    sourceWord: escapeHTML(item.word),
                    phonetic: escapeHTMLPreservingLineBreaks(
                        AnkiFieldFormatter.phoneticDisplay(
                            from: result,
                            aiArtifacts: previewArtifacts
                        )
                    ),
                    definitionsHTML: AnkiFieldFormatter.definitionsHTML(
                        from: result,
                        aiArtifacts: previewArtifacts
                    ),
                    audioFilename: item.audioData.map { _ in
                        item.word
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: " ", with: "_")
                            .lowercased() + ".wav"
                    },
                    audioData: item.audioData,
                    sortField: item.word,
                    guidSeed: "\(item.word.lowercased())|preview|recall"
                )
                VStack(spacing: 0) {
                    previewBanner
                    AnkiCardWebView(html: AnkiFieldFormatter.renderCardHTML(note: note, showBack: showBack))
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No Saved Recall Card yet.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Save a draft in AI Assistant to preview the Saved Recall Card here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: generateRecallDraftFromPreview) {
                        if isGeneratingRecallPreviewDraft {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Generate Draft", systemImage: "sparkles.rectangle.stack")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help(recallPreviewActionHelpText)
                    .disabled(isGeneratingRecallPreviewDraft || item.lookupResult == nil || isActionBlocked(for: .recallCard))
                    if let recallPreviewFeedback {
                        Text(recallPreviewFeedback)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let recallPreviewErrorMessage {
                        Text(recallPreviewErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadingView(text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activePreviewArtifacts: AIArtifacts {
        agentPreviewOverrideArtifacts ?? item.aiArtifacts
    }

    private var previewRecallDraft: RecallCardDraft? {
        activePreviewArtifacts.acceptedRecallCardDrafts.first ?? item.aiAcceptedRecallCardDrafts.first
    }

    @ViewBuilder
    private var previewBanner: some View {
        if agentPreviewOverrideArtifacts != nil {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundStyle(.orange)
                Text("Reviewing Agent proposal")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }

    private func configureAgentSession() {
        guard item.isReady,
              let databaseURL = viewModel.wordListStore?.databaseURL else {
            agentSession = nil
            return
        }

        let bridge = WordItemAgentBridge(
            item: item,
            viewModel: viewModel,
            snapshotMode: { [previewFamily] in
                previewFamily == .recall ? .recall : .standard
            }
        )
        let session = AgentSession(
            wordID: item.id,
            persistence: AgentSessionStore(databaseURL: databaseURL),
            snapshotProvider: bridge,
            artifactsManager: bridge,
            generator: LLMAgentGeneratorAdapter(llmService: llmService)
        )
        try? session.reload()
        self.agentSession = session
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Lookup failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Retry") { viewModel.retryLookup(item) }
                .buttonStyle(.bordered)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generateRecallDraftFromPreview() {
        guard prepareManualGeneration() else { return }
        guard let result = item.lookupResult else { return }
        let senses = recallPromptInputs(from: result)
        guard !senses.isEmpty else {
            recallPreviewErrorMessage = "Recall needs at least one usable sense before generating a draft."
            return
        }

        isGeneratingRecallPreviewDraft = true
        recallPreviewFeedback = nil
        recallPreviewErrorMessage = nil

        Task {
            do {
                let decision = try await llmService.generateRecallCardDraftDecision(
                    word: item.word,
                    senses: senses,
                    context: recallGenerationContext,
                    allowedModes: recommendedRecallAllowedModes,
                    modePrior: recommendedRecallModePrior,
                    anchor: LLMAnchorSnapshot(text: item.word, note: "Preview quick-start")
                )
                let generated = decision.draft
                let draft = RecallCardDraft(
                    mode: RecallCardMode(rawValue: generated.mode.rawValue) ?? .fullSpelling,
                    front: generated.front,
                    back: generated.back,
                    hint: generated.hint,
                    anchor: generated.anchor.map {
                        AIArtifactAnchorSnapshot(headword: $0.text, lexicalEntryIndex: nil, senseIndex: nil, exampleIndex: nil, excerpt: $0.note)
                    }
                )

                await MainActor.run {
                    viewModel.saveAISuggestedRecallCardDrafts([draft], for: item)
                    isGeneratingRecallPreviewDraft = false
                    recallPreviewFeedback = "Draft added to AI Assistant below. Save it there to preview the card here."
                }
            } catch {
                await MainActor.run {
                    isGeneratingRecallPreviewDraft = false
                    if !presentAIUnavailableAlertIfNeeded(for: error) {
                        recallPreviewErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func recallPromptInputs(from result: LookupResult) -> [LLMSensePromptInput] {
        var seen = Set<String>()
        var inputs: [LLMSensePromptInput] = []

        for entry in result.entries {
            for lexical in entry.lexicalEntries {
                for sense in lexical.senses {
                    let definition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !definition.isEmpty else { continue }
                    let input = LLMSensePromptInput(
                        partOfSpeech: lexical.partOfSpeechLabel,
                        definition: definition,
                        semanticHint: sense.semanticHint
                    )
                    let key = [
                        input.partOfSpeech.lowercased(),
                        input.definition.lowercased(),
                        (input.semanticHint ?? "").lowercased()
                    ].joined(separator: "|")
                    guard seen.insert(key).inserted else { continue }
                    inputs.append(input)
                }
            }
        }

        return inputs
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

    private var pronunciationAutoGenerationTaskKey: String {
        [
            item.id.uuidString,
            item.isReady ? "ready" : "not-ready",
            llmService.serverState.isRunning ? "server-running" : "server-stopped",
            "\(item.generatedIPANotationsByDialect.count)",
            "\(item.generatedStressSyllablesByDialect.count)"
        ].joined(separator: "|")
    }

    private func triggerAutomaticPronunciationEnhancementIfNeeded() {
        guard item.isReady, llmService.serverState.isRunning else { return }

        let phonetics = item.phoneticsByDialect
        if phonetics.isEmpty {
            let dialectKey = item.dialectStorageKey(for: "AmE")
            guard item.generatedStressSyllablesByDialect[dialectKey] == nil else { return }
            guard attemptedAutomaticPronunciationDialects.insert(dialectKey).inserted else { return }
            generatePronunciationEnhancement(for: "AmE", guide: nil, existingIPA: item.preferredGeneratedIPA, automatic: true)
            return
        }

        for entry in phonetics {
            let dialectKey = item.dialectStorageKey(for: entry.dialect)
            guard item.generatedStressSyllablesByDialect[dialectKey] == nil else { continue }
            guard attemptedAutomaticPronunciationDialects.insert(dialectKey).inserted else { continue }
            generatePronunciationEnhancement(
                for: entry.dialect,
                guide: entry.notation,
                existingIPA: entry.usesIPADelimiters ? entry.notation : item.generatedIPANotationsByDialect[dialectKey],
                automatic: true
            )
        }
    }

    private func generatePronunciationEnhancement(
        for dialect: String?,
        guide: String?,
        existingIPA: String?,
        automatic: Bool = false
    ) {
        if automatic {
            guard !LLMGenerationAvailability.shouldPromptForManualAction(
                hasModel: llmService.hasModel,
                serverState: llmService.serverState
            ) else {
                return
            }
        } else {
            guard prepareManualGeneration() else { return }
        }

        guard let result = item.lookupResult else { return }
        let dialectKey = item.dialectStorageKey(for: dialect)
        guard !generatingPronunciationDialects.contains(dialectKey) else { return }
        let senses = recallPromptInputs(from: result)

        if !automatic {
            attemptedAutomaticPronunciationDialects.insert(dialectKey)
        }

        generatingPronunciationDialects.insert(dialectKey)
        pronunciationEnhancementErrorMessage = nil

        Task {
            do {
                let enhancement = try await llmService.generatePronunciationEnhancement(
                    word: item.word,
                    dialect: dialect,
                    pronunciationGuide: guide,
                    existingIPA: existingIPA,
                    senses: senses
                )
                await MainActor.run {
                    if let ipa = enhancement.ipa {
                        viewModel.saveGeneratedIPA(ipa, dialect: dialect, for: item)
                    }
                    viewModel.saveGeneratedStressSyllables(enhancement.stressSyllables, dialect: dialect, for: item)
                    generatingPronunciationDialects.remove(dialectKey)
                }
            } catch {
                await MainActor.run {
                    generatingPronunciationDialects.remove(dialectKey)
                    if automatic {
                        return
                    }
                    if !presentAIUnavailableAlertIfNeeded(for: error) {
                        pronunciationEnhancementErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func preferredStressRefreshTarget(
        from phonetics: [(dialect: String, notation: String, usesIPADelimiters: Bool, pronunciation: Pronunciation)]
    ) -> (dialect: String, guide: String, existingIPA: String?)? {
        let preferredDialects = ["AmE", "BrE"]

        for dialect in preferredDialects {
            let dialectKey = item.dialectStorageKey(for: dialect)
            guard item.generatedStressSyllablesByDialect[dialectKey] != nil else { continue }
            if let entry = phonetics.first(where: { item.dialectStorageKey(for: $0.dialect) == dialectKey }) {
                return (
                    dialect: entry.dialect,
                    guide: entry.notation,
                    existingIPA: entry.usesIPADelimiters ? entry.notation : item.generatedIPANotationsByDialect[dialectKey]
                )
            }
        }

        if let dialectKey = item.generatedStressSyllablesByDialect.keys.first,
           let entry = phonetics.first(where: { item.dialectStorageKey(for: $0.dialect) == dialectKey }) {
            return (
                dialect: entry.dialect,
                guide: entry.notation,
                existingIPA: entry.usesIPADelimiters ? entry.notation : item.generatedIPANotationsByDialect[dialectKey]
            )
        }

        if let entry = phonetics.first {
            let dialectKey = item.dialectStorageKey(for: entry.dialect)
            return (
                dialect: entry.dialect,
                guide: entry.notation,
                existingIPA: entry.usesIPADelimiters ? entry.notation : item.generatedIPANotationsByDialect[dialectKey]
            )
        }

        return nil
    }

    @ViewBuilder
    private func pronunciationActionGroup(
        isGenerating: Bool,
        canRefresh: Bool,
        canPlay: Bool,
        refreshHelp: String,
        onRefresh: @escaping () -> Void,
        onPlay: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 1) {
            pronunciationIconButton(
                systemImage: "arrow.clockwise",
                help: refreshHelp,
                tint: Self.generateIPATint,
                isLoading: isGenerating,
                disabled: !canRefresh || isGenerating,
                action: onRefresh
            )

            pronunciationIconButton(
                systemImage: "speaker.wave.2.fill",
                help: "Play pronunciation",
                tint: .secondary,
                isLoading: false,
                disabled: !canPlay,
                action: onPlay
            )
        }
    }

    @ViewBuilder
    private func pronunciationIconButton(
        systemImage: String,
        help: String,
        tint: Color,
        isLoading: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : tint.opacity(0.9))
        .help(help)
        .disabled(disabled)
    }

    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func escapeHTMLPreservingLineBreaks(_ text: String) -> String {
        escapeHTML(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private func recallInstruction(for mode: RecallCardMode) -> String {
        switch mode {
        case .fullSpelling:
            return "Recall the full spelling before revealing the answer."
        case .targetedLetterCloze:
            return "Rebuild the missing spelling segment instead of just recognizing the word."
        case .phraseRecall:
            return "Use the cue to actively retrieve the missing word in context."
        }
    }

    private func prepareManualGeneration() -> Bool {
        if LLMGenerationAvailability.shouldPromptForManualAction(
            hasModel: llmService.hasModel,
            serverState: llmService.serverState
        ) {
            unavailableAlertContent = LLMGenerationAvailability.alertContent(for: generationAvailabilityState)
            return false
        }

        return true
    }

    private func presentAIUnavailableAlertIfNeeded(for error: Error) -> Bool {
        guard LLMGenerationAvailability.shouldPromptForManualAction(
            hasModel: llmService.hasModel,
            serverState: llmService.serverState,
            error: error
        ) else {
            return false
        }

        unavailableAlertContent = LLMGenerationAvailability.alertContent(
            for: LLMGenerationAvailability.resolvedState(
                hasModel: llmService.hasModel,
                serverState: llmService.serverState,
                error: error
            )
        )
        return true
    }

    private func isActionBlocked(for action: LLMGenerationAvailability.Action) -> Bool {
        switch generationAvailabilityState {
        case .noModelConfigured, .runtimeMissing, .serviceFailedToStart:
            return true
        case .available, .modelAvailableServiceIdle, .preparing, .temporarilyUnavailable:
            return false
        }
    }

    private func pronunciationActionHelpText(defaultText: String) -> String {
        LLMGenerationAvailability.actionMessage(
            for: .pronunciationEnhancement,
            state: generationAvailabilityState
        ) ?? defaultText
    }

    private var recallPreviewActionHelpText: String {
        LLMGenerationAvailability.actionMessage(
            for: .recallCard,
            state: generationAvailabilityState
        ) ?? "Generate Draft"
    }

}

private enum PreviewFamily: String, CaseIterable, Hashable {
    case standard
    case recall
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

enum CardPreviewAIPanelLayout {
    static let persistedRatioRange: ClosedRange<CGFloat> = 0.2...0.92

    static func restoredHeight(
        fromPersistedRatio ratio: Double,
        availableHeight: CGFloat,
        minHeight: CGFloat,
        minTopHeight: CGFloat
    ) -> CGFloat {
        clampedHeight(
            CGFloat(ratio) * availableHeight,
            availableHeight: availableHeight,
            minHeight: minHeight,
            minTopHeight: minTopHeight
        )
    }

    static func clampedHeight(
        _ value: CGFloat,
        availableHeight: CGFloat,
        minHeight: CGFloat,
        minTopHeight: CGFloat
    ) -> CGFloat {
        let maxAllowedHeight = max(
            minHeight,
            availableHeight - minTopHeight
        )
        return min(
            max(value, minHeight),
            min(maxAllowedHeight, availableHeight * persistedRatioRange.upperBound)
        )
    }

    static func persistedRatio(forHeight height: CGFloat, availableHeight: CGFloat) -> Double {
        Double((height / max(availableHeight, 1)).clamped(to: persistedRatioRange))
    }
}

enum CardPreviewHTMLReloadPolicy {
    static func shouldReload(previousHTML: String?, nextHTML: String) -> Bool {
        previousHTML != nextHTML
    }
}

struct CardPreviewSplitView<TopContent: View, BottomContent: View>: NSViewControllerRepresentable {
    let desiredBottomHeight: CGFloat
    let availableHeight: CGFloat
    let minBottomHeight: CGFloat
    let minTopHeight: CGFloat
    let persistedRatio: Double
    let onBottomHeightCommit: (CGFloat) -> Void
    let topContent: TopContent
    let bottomContent: BottomContent

    func makeNSViewController(context: Context) -> CardPreviewSplitViewController {
        let controller = CardPreviewSplitViewController()
        controller.onBottomHeightCommit = onBottomHeightCommit
        controller.configureLayout(
            availableHeight: availableHeight,
            minBottomHeight: minBottomHeight,
            minTopHeight: minTopHeight
        )
        controller.updateTop(rootView: AnyView(topContent))
        controller.updateBottom(rootView: AnyView(bottomContent))
        controller.apply(
            bottomHeight: desiredBottomHeight,
            persistedRatio: persistedRatio
        )
        return controller
    }

    func updateNSViewController(_ controller: CardPreviewSplitViewController, context: Context) {
        controller.onBottomHeightCommit = onBottomHeightCommit
        controller.configureLayout(
            availableHeight: availableHeight,
            minBottomHeight: minBottomHeight,
            minTopHeight: minTopHeight
        )
        controller.updateTop(rootView: AnyView(topContent))
        controller.updateBottom(rootView: AnyView(bottomContent))
        controller.apply(
            bottomHeight: desiredBottomHeight,
            persistedRatio: persistedRatio
        )
    }
}

final class CardPreviewSplitViewController: NSViewController, NSSplitViewDelegate {
    private let splitView = CardPreviewNativeSplitView()
    private let topHostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let bottomHostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let topContainerView = CardPreviewLiveResizeContainerView()
    private let bottomContainerView = CardPreviewLiveResizeContainerView()

    var onBottomHeightCommit: ((CGFloat) -> Void)?

    private var availableHeight: CGFloat = 0
    private var minBottomHeight: CGFloat = 180
    private var minTopHeight: CGFloat = 96
    private var isApplyingProgrammaticLayout = false
    private var pendingBottomHeight: CGFloat?
    private var persistedRatio: Double = 0.38

    override func loadView() {
        splitView.isVertical = false
        splitView.delegate = self
        splitView.dividerStyle = .thin
        splitView.autosaveName = NSSplitView.AutosaveName("")
        topContainerView.embed(topHostingController.view)
        bottomContainerView.embed(bottomHostingController.view)
        splitView.topView = topContainerView
        splitView.bottomView = bottomContainerView
        splitView.onDividerDragEnded = { [weak self] in
            self?.commitCurrentBottomHeight()
        }
        view = splitView
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        if let pendingBottomHeight {
            applyBottomHeight(pendingBottomHeight)
            self.pendingBottomHeight = nil
        }
    }

    func configureLayout(
        availableHeight: CGFloat,
        minBottomHeight: CGFloat,
        minTopHeight: CGFloat
    ) {
        self.availableHeight = availableHeight
        self.minBottomHeight = minBottomHeight
        self.minTopHeight = minTopHeight
    }

    func updateTop(rootView: AnyView) {
        topHostingController.rootView = rootView
    }

    func updateBottom(rootView: AnyView) {
        bottomHostingController.rootView = rootView
    }

    func apply(bottomHeight: CGFloat, persistedRatio: Double) {
        self.persistedRatio = persistedRatio

        let resolvedHeight: CGFloat
        if bottomHeight > 0 {
            resolvedHeight = bottomHeight
        } else {
            resolvedHeight = CardPreviewAIPanelLayout.restoredHeight(
                fromPersistedRatio: persistedRatio,
                availableHeight: effectiveAvailableHeight,
                minHeight: minBottomHeight,
                minTopHeight: minTopHeight
            )
        }

        applyBottomHeight(resolvedHeight)
    }

    private var effectiveAvailableHeight: CGFloat {
        max(splitView.bounds.height, availableHeight)
    }

    private func applyBottomHeight(_ height: CGFloat) {
        guard splitView.bounds.height > 0 else {
            pendingBottomHeight = height
            return
        }

        let bottomHeight = CardPreviewAIPanelLayout.clampedHeight(
            height,
            availableHeight: splitView.bounds.height,
            minHeight: minBottomHeight,
            minTopHeight: minTopHeight
        )
        let topHeight = splitView.bounds.height - splitView.dividerThickness - bottomHeight
        isApplyingProgrammaticLayout = true
        splitView.setPosition(max(0, topHeight), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        isApplyingProgrammaticLayout = false
    }

    private func commitCurrentBottomHeight() {
        let height = CardPreviewAIPanelLayout.clampedHeight(
            splitView.currentBottomHeight,
            availableHeight: splitView.bounds.height,
            minHeight: minBottomHeight,
            minTopHeight: minTopHeight
        )
        onBottomHeightCommit?(height)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let totalHeight = splitView.bounds.height
        let dividerThickness = splitView.dividerThickness
        let minPosition = minTopHeight
        let maxPosition = totalHeight - dividerThickness - minBottomHeight
        return min(max(proposedPosition, minPosition), maxPosition)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingProgrammaticLayout else { return }

        pendingBottomHeight = nil
    }
}

final class CardPreviewNativeSplitView: NSSplitView {
    var onDividerDragEnded: (() -> Void)?

    var topView: NSView? {
        didSet {
            guard let topView else { return }
            installArrangedSubview(topView, at: 0)
        }
    }

    var bottomView: NSView? {
        didSet {
            guard let bottomView else { return }
            installArrangedSubview(bottomView, at: 1)
        }
    }

    var currentBottomHeight: CGFloat {
        arrangedSubviews.count > 1 ? arrangedSubviews[1].frame.height : 0
    }

    override var dividerThickness: CGFloat {
        16
    }

    override func drawDivider(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        let handleRect = NSRect(
            x: rect.midX - 28,
            y: rect.midY - 3,
            width: 56,
            height: 6
        )
        let path = NSBezierPath(roundedRect: handleRect, xRadius: 3, yRadius: 3)
        NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
        path.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = dividerHitRect
        guard !rect.isEmpty else { return }
        addCursorRect(rect, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let didHitDivider = dividerHitRect.contains(location)
        super.mouseDown(with: event)
        if didHitDivider {
            onDividerDragEnded?()
        }
    }

    private var dividerHitRect: NSRect {
        guard arrangedSubviews.count >= 2 else { return .zero }
        let topFrame = arrangedSubviews[0].frame
        return NSRect(
            x: 0,
            y: topFrame.maxY,
            width: bounds.width,
            height: dividerThickness
        )
    }

    private func installArrangedSubview(_ view: NSView, at index: Int) {
        if arrangedSubviews.indices.contains(index), arrangedSubviews[index] === view {
            return
        }

        if arrangedSubviews.contains(view) {
            return
        }

        if arrangedSubviews.indices.contains(index) {
            let existing = arrangedSubviews[index]
            removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }

        insertArrangedSubview(view, at: index)
        view.translatesAutoresizingMaskIntoConstraints = true
    }
}

final class CardPreviewLiveResizeContainerView: NSView {
    override var preservesContentDuringLiveResize: Bool {
        true
    }

    func embed(_ contentView: NSView) {
        guard contentView.superview !== self else { return }
        subviews.forEach { existing in
            existing.removeFromSuperview()
        }
        addSubview(contentView)
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
    }
}

struct AnkiCardWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard CardPreviewHTMLReloadPolicy.shouldReload(
            previousHTML: context.coordinator.lastLoadedHTML,
            nextHTML: html
        ) else {
            return
        }
        context.coordinator.lastLoadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastLoadedHTML: String?
    }
}
