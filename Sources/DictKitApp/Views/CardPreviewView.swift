import DictKitAnkiExport
import SwiftUI
import WebKit

struct CardPreviewView: View {
    @ObservedObject var item: WordItem
    @EnvironmentObject var viewModel: WordListViewModel
    @State private var showBack: Bool = true
    @AppStorage("cardPreview.aiPanelRatio") private var aiPanelRatio: Double = 0.38
    @State private var aiPanelHeight: CGFloat = 320
    @State private var dragStartHeight: CGFloat?

    private let minAIPanelHeight: CGFloat = 180
    private let maxAIPanelHeight: CGFloat = 520

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                // Row 1: Word title + retry + spacer + Front/Back picker
                HStack {
                    Text(item.word)
                        .font(.title2.bold())

                    if item.isReady {
                        Button(action: {
                            viewModel.retryLookup(item)
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Re-lookup with current dictionary")
                    }

                    Spacer()

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

                // Row 2: Phonetics with dialect badges (AmE first, then BrE)
                let phonetics = item.phoneticsByDialect.sorted { a, b in
                    let order = ["AmE": 0, "BrE": 1]
                    return (order[a.dialect] ?? 2) < (order[b.dialect] ?? 2)
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

                        if phonetics.isEmpty {
                            Button(action: {
                                Task { await viewModel.playPronunciation(for: item) }
                            }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!item.isReady)
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

            // Card preview
                Group {
                if let result = item.lookupResult {
                    let note = AnkiNoteData(
                        word: item.word,
                        phonetic: AnkiFieldFormatter.phonetic(from: result),
                        definitions: AnkiFieldFormatter.definitionsHTML(
                            from: result,
                            aiAcceptedExampleSentences: item.aiAcceptedExampleSentences,
                            aiAcceptedDefinitionNote: item.aiAcceptedDefinitionNote
                        ),
                        audioFilename: nil,
                        audioData: nil
                    )
                    let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: showBack)
                    AnkiCardWebView(html: html)
                } else if case .loading = item.lookupState {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Looking up...")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if case .failed(let msg) = item.lookupState {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text("Lookup failed")
                            .font(.headline)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button("Retry") {
                            viewModel.retryLookup(item)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("Pending...")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // AI Content
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
                aiPanelHeight = clampHeight(
                    CGFloat(aiPanelRatio) * geometry.size.height,
                    availableHeight: geometry.size.height
                )
            }
            .onChange(of: geometry.size.height) { newHeight in
                aiPanelHeight = clampHeight(CGFloat(aiPanelRatio) * newHeight, availableHeight: newHeight)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
                    if dragStartHeight == nil {
                        dragStartHeight = aiPanelHeight
                    }
                    let next = clampHeight(start - value.translation.height, availableHeight: availableHeight)
                    aiPanelHeight = next
                    aiPanelRatio = Double((next / max(availableHeight, 1)).clamped(to: 0.2...0.75))
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
    }

    private func clampHeight(_ value: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(max(value, minAIPanelHeight), min(maxAIPanelHeight, availableHeight * 0.75))
    }
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
