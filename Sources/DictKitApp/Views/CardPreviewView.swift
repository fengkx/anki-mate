import AnkiMateLLM
import DictKit
import DictKitAnkiExport
import SwiftUI
import WebKit

struct CardPreviewView: View {
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
    @State private var generatingIPADialects = Set<String>()
    @State private var generatedIPAErrorMessage: String?

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

                                    if !entry.usesIPADelimiters && generatedIPA == nil {
                                        if !item.hasDisplayIPA {
                                            Button(action: {
                                                generateIPA(for: entry.dialect, guide: entry.notation)
                                            }) {
                                                if generatingIPADialects.contains(dialectKey) {
                                                    ProgressView()
                                                        .controlSize(.small)
                                                        .frame(minWidth: 72)
                                                } else {
                                                    Label("Generate IPA", systemImage: "sparkles")
                                                        .labelStyle(.titleAndIcon)
                                                }
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .tint(Color.accentColor.opacity(0.9))
                                            .disabled(generatingIPADialects.contains(dialectKey))
                                        }
                                    }
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
                    } else {
                        HStack(alignment: .center, spacing: 10) {
                            let defaultDialectKey = item.dialectStorageKey(for: "AmE")
                            let generatedIPA = item.preferredGeneratedIPA

                            Button(action: {
                                Task { await viewModel.playPronunciation(for: item) }
                            }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!item.isReady)

                            if !item.hasDisplayIPA {
                                if generatedIPA == nil {
                                    Button(action: {
                                        generateIPA(for: "AmE", guide: nil)
                                    }) {
                                        if generatingIPADialects.contains(defaultDialectKey) {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(minWidth: 72)
                                        } else {
                                            Label("Generate IPA", systemImage: "sparkles")
                                                .labelStyle(.titleAndIcon)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .tint(Color.accentColor.opacity(0.9))
                                    .disabled(!item.isReady || generatingIPADialects.contains(defaultDialectKey))
                                }
                            }

                            if let generatedIPA {
                                Text("/\(generatedIPA)/")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    if let generatedIPAErrorMessage {
                        Text(generatedIPAErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

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
                    phonetic: item.phonetic,
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
            if let draft = item.aiAcceptedRecallCardDrafts.first {
                AnkiCardWebView(html: recallPreviewHTML(for: draft, showBack: showBack))
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

    private func generateIPA(for dialect: String?, guide: String?) {
        guard let result = item.lookupResult else { return }
        let dialectKey = item.dialectStorageKey(for: dialect)
        let senses = recallPromptInputs(from: result)

        generatingIPADialects.insert(dialectKey)
        generatedIPAErrorMessage = nil

        Task {
            do {
                let generatedIPA = try await llmService.generatePhoneticIPA(
                    word: item.word,
                    dialect: dialect,
                    pronunciationGuide: guide,
                    senses: senses
                )
                await MainActor.run {
                    viewModel.saveGeneratedIPA(generatedIPA, dialect: dialect, for: item)
                    generatingIPADialects.remove(dialectKey)
                }
            } catch {
                await MainActor.run {
                    generatingIPADialects.remove(dialectKey)
                    generatedIPAErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func recallPreviewHTML(for draft: RecallCardDraft, showBack: Bool) -> String {
        let front = """
        <div class="front">
          <div class="word">\(escapeHTML(draft.front))</div>
          <div class="phonetic">\(escapeHTML(draft.mode.displayName))</div>
        </div>
        """

        let body: String
        if showBack {
            body = """
            \(front)
            <hr id="answer">
            <div class="back">
              <div class="recall-back">\(escapeHTMLPreservingLineBreaks(draft.back))</div>
              \(draft.hint.map { hint in "<div class=\"recall-hint\">\(escapeHTMLPreservingLineBreaks(hint))</div>" } ?? "")
            </div>
            """
        } else {
            body = front
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(AnkiCardTemplate.css)
        .recall-back { font-size: 24px; font-weight: 700; line-height: 1.4; }
        .recall-hint { margin-top: 12px; color: #6b7280; font-size: 16px; }
        </style>
        </head>
        <body class="card">
        \(body)
        </body>
        </html>
        """
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
