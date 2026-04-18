import AnkiMateLLM
import DictKit
import DictKitAnkiExport
import SwiftUI
import WebKit

struct CardPreviewView: View {
    private static let generateIPATint = Color.blue.opacity(0.9)

    @ObservedObject var item: WordItem
    @EnvironmentObject var llmService: LLMService
    @EnvironmentObject var viewModel: WordListViewModel
    @State private var showBack: Bool = true
    @State private var previewFamily: PreviewFamily = .standard
    @AppStorage("cardPreview.aiPanelRatio") private var aiPanelRatio: Double = 0.38
    @State private var aiPanelHeight: CGFloat = 320
    @State private var dragStartHeight: CGFloat?
    @State private var isGeneratingRecallPreviewDraft = false
    @State private var recallPreviewFeedback: String?
    @State private var recallPreviewErrorMessage: String?
    @State private var generatingPronunciationDialects = Set<String>()
    @State private var pronunciationEnhancementErrorMessage: String?
    @State private var attemptedAutomaticPronunciationDialects = Set<String>()

    private let minAIPanelHeight: CGFloat = 180
    private let maxAIPanelHeight: CGFloat = 520

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(item.word)
                            .font(.title2.bold())

                        if item.isReady {
                            Button(action: { viewModel.retryLookup(item) }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Re-lookup with current dictionary")
                        }

                        Spacer()

                        Picker("", selection: $previewFamily) {
                            Text("Standard").tag(PreviewFamily.standard)
                            Text("Recall").tag(PreviewFamily.recall)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)

                        Picker("", selection: $showBack) {
                            Text("Front").tag(false)
                            Text("Back").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
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

                    let phonetics = item.phoneticsByDialect.sorted {
                        let order = ["AmE": 0, "BrE": 1]
                        return (order[$0.dialect] ?? 2) < (order[$1.dialect] ?? 2)
                    }
                    if !phonetics.isEmpty {
                        let sharedStressRefreshTarget = preferredStressRefreshTarget(from: phonetics)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 18) {
                                ForEach(Array(phonetics.enumerated()), id: \.offset) { _, entry in
                                    let dialectKey = item.dialectStorageKey(for: entry.dialect)
                                    let generatedIPA = item.generatedIPANotationsByDialect[dialectKey]

                                    HStack(alignment: .center, spacing: 8) {
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

                                        Button(action: {
                                            generatePronunciationEnhancement(
                                                for: entry.dialect,
                                                guide: entry.notation,
                                                existingIPA: entry.usesIPADelimiters ? entry.notation : generatedIPA
                                            )
                                        }) {
                                            if generatingPronunciationDialects.contains(dialectKey) {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                                    .font(.caption)
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(Self.generateIPATint)
                                        .help("Generate pronunciation aid")
                                        .disabled(generatingPronunciationDialects.contains(dialectKey))

                                        Button(action: {
                                            Task { await viewModel.playPronunciation(for: item, pronunciation: entry.pronunciation) }
                                        }) {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }

                            if let sharedStressSyllables = item.preferredGeneratedStressSyllables {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(sharedStressSyllables)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .help("Stress syllables")

                                    if let target = sharedStressRefreshTarget {
                                        let dialectKey = item.dialectStorageKey(for: target.dialect)
                                        Button(action: {
                                            generatePronunciationEnhancement(
                                                for: target.dialect,
                                                guide: target.guide,
                                                existingIPA: target.existingIPA
                                            )
                                        }) {
                                            if generatingPronunciationDialects.contains(dialectKey) {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                                    .font(.caption)
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(Self.generateIPATint)
                                        .help("Regenerate stress syllables")
                                        .disabled(!item.isReady || generatingPronunciationDialects.contains(dialectKey))
                                    }
                                }
                            }
                        }
                    } else {
                        HStack(alignment: .center, spacing: 10) {
                            let defaultDialectKey = item.dialectStorageKey(for: "AmE")
                            let generatedIPA = item.preferredGeneratedIPA
                            let generatedStressSyllables = item.generatedStressSyllables(for: "AmE")

                            if let generatedIPA {
                                Text("/\(generatedIPA)/")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                            }

                            if let generatedStressSyllables {
                                Text(generatedStressSyllables)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            Button(action: {
                                generatePronunciationEnhancement(
                                    for: "AmE",
                                    guide: nil,
                                    existingIPA: generatedIPA
                                )
                            }) {
                                if generatingPronunciationDialects.contains(defaultDialectKey) {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Self.generateIPATint)
                            .help("Generate pronunciation aid")
                            .disabled(!item.isReady || generatingPronunciationDialects.contains(defaultDialectKey))

                            Button(action: {
                                Task { await viewModel.playPronunciation(for: item) }
                            }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!item.isReady)
                        }
                    }
                    if let pronunciationEnhancementErrorMessage {
                        Text(pronunciationEnhancementErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .task(id: pronunciationAutoGenerationTaskKey) {
                    triggerAutomaticPronunciationEnhancementIfNeeded()
                }
                .onChange(of: item.id) { _ in
                    attemptedAutomaticPronunciationDialects = []
                    pronunciationEnhancementErrorMessage = nil
                }

                Divider()

                Group {
                    switch previewFamily {
                    case .standard:
                        standardPreview
                    case .recall:
                        recallPreview
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if item.isReady {
                    Divider()
                    resizeHandle(availableHeight: geometry.size.height)
                    AIContentView(item: item)
                        .id(item.id)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(height: aiPanelHeight)
                }
            }
            .onAppear {
                aiPanelHeight = clampHeight(CGFloat(aiPanelRatio) * geometry.size.height, availableHeight: geometry.size.height)
            }
            .onChange(of: geometry.size.height) { newHeight in
                aiPanelHeight = clampHeight(CGFloat(aiPanelRatio) * newHeight, availableHeight: newHeight)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var standardPreview: some View {
        Group {
            if let result = item.lookupResult {
                let note = AnkiNoteData(
                    word: item.word,
                    phonetic: AnkiFieldFormatter.phoneticDisplay(
                        from: result,
                        aiArtifacts: item.aiArtifacts
                    ),
                    definitions: AnkiFieldFormatter.definitionsHTML(
                        from: result,
                        aiArtifacts: item.aiArtifacts
                    ),
                    audioFilename: nil,
                    audioData: nil
                )
                AnkiCardWebView(html: AnkiFieldFormatter.renderCardHTML(note: note, showBack: showBack))
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
            if let draft = item.aiAcceptedRecallCardDrafts.first, let result = item.lookupResult {
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
                            aiArtifacts: item.aiArtifacts
                        )
                    ),
                    definitionsHTML: AnkiFieldFormatter.definitionsHTML(
                        from: result,
                        aiArtifacts: item.aiArtifacts
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
                AnkiCardWebView(html: AnkiFieldFormatter.renderCardHTML(note: note, showBack: showBack))
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
                    .disabled(isGeneratingRecallPreviewDraft || item.lookupResult == nil)
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
                let mode = defaultRecallMode
                let generated = try await llmService.generateRecallCardDraft(
                    word: item.word,
                    senses: senses,
                    mode: mode,
                    anchor: LLMAnchorSnapshot(text: item.word, note: "Preview quick-start")
                )
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
                    recallPreviewErrorMessage = error.localizedDescription
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

    private var defaultRecallMode: LLMRecallCardMode {
        if item.word.contains(" ") {
            return .phraseRecall
        }
        if item.word.count >= 9 {
            return .targetedLetterCloze
        }
        return .fullSpelling
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
                    if !automatic {
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

    private func resizeHandle(availableHeight: CGFloat) -> some View {
        HStack {
            Spacer()
            RoundedRectangle(cornerRadius: 3)
                .fill(.secondary.opacity(0.6))
                .frame(width: 56, height: 6)
            Spacer()
        }
        .contentShape(Rectangle())
        .hoverCursor(.resizeUpDown)
        .padding(.vertical, 6)
        .background(.background.opacity(0.85))
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStartHeight ?? aiPanelHeight
                    if dragStartHeight == nil { dragStartHeight = aiPanelHeight }
                    let next = clampHeight(start - value.translation.height, availableHeight: availableHeight)
                    aiPanelHeight = next
                    aiPanelRatio = Double((next / max(availableHeight, 1)).clamped(to: 0.2...0.75))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }

    private func clampHeight(_ value: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(max(value, minAIPanelHeight), min(maxAIPanelHeight, availableHeight * 0.75))
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

struct AnkiCardWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
