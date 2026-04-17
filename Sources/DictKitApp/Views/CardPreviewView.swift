import DictKitAnkiExport
import SwiftUI
import WebKit

struct CardPreviewView: View {
    @ObservedObject var item: WordItem
    @EnvironmentObject var viewModel: WordListViewModel
    @State private var showBack: Bool = true
    @State private var previewFamily: PreviewFamily = .standard
    @AppStorage("cardPreview.aiPanelRatio") private var aiPanelRatio: Double = 0.38
    @State private var aiPanelHeight: CGFloat = 320
    @State private var dragStartHeight: CGFloat?

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
                        HStack(spacing: 20) {
                            ForEach(Array(phonetics.enumerated()), id: \.offset) { _, entry in
                                HStack(spacing: 4) {
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
                                    Text("/\(entry.ipa)/")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
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
                        HStack {
                            Button(action: {
                                Task { await viewModel.playPronunciation(for: item) }
                            }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!item.isReady)
                        }
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
                    phonetic: AnkiFieldFormatter.phonetic(from: result),
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
                    Text("No accepted recall draft yet.")
                        .font(.body)
                        .foregroundStyle(.secondary)
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
