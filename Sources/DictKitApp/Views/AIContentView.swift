import SwiftUI
import DictKit
import AnkiMateLLM

struct AIContentView: View {
    @ObservedObject var item: WordItem
    @EnvironmentObject private var llmService: LLMService
    @EnvironmentObject private var viewModel: WordListViewModel

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Assistant", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                if item.isGeneratingAI {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !llmService.hasModel {
                noModelView
            } else {
                actionButtons
                sentencesSection
                definitionNoteSection
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                Label("Generate Sentences", systemImage: "text.quote")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(item.isGeneratingAI || !llmService.hasModel)

            Button {
                optimizeDefinition()
            } label: {
                Label("Optimize Definition", systemImage: "text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(item.isGeneratingAI || !llmService.hasModel || firstDefinition == nil)
        }
    }

    // MARK: - Sentences Section

    @ViewBuilder
    private var sentencesSection: some View {
        if !item.aiExampleSentences.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Example Sentences")
                        .font(.subheadline.bold())
                    Spacer()
                    Button(role: .destructive) {
                        viewModel.saveAIExampleSentences([], for: item)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                ForEach(Array(item.aiExampleSentences.enumerated()), id: \.offset) { index, sentence in
                    Text("\(index + 1). \(sentence)")
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Definition Note Section

    @ViewBuilder
    private var definitionNoteSection: some View {
        if let note = item.aiDefinitionNote {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Learner Definition")
                        .font(.subheadline.bold())
                    Spacer()
                    Button(role: .destructive) {
                        viewModel.saveAIDefinitionNote(nil, for: item)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Text(note)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func generateSentences() {
        guard let result = item.lookupResult else { return }

        // Find the first usable definition
        guard let (pos, definition) = firstSenseInfo(from: result) else { return }

        item.isGeneratingAI = true
        errorMessage = nil

        Task {
            do {
                let sentences = try await llmService.generateExampleSentences(
                    word: item.word,
                    definition: definition,
                    partOfSpeech: pos
                )
                viewModel.saveAIExampleSentences(sentences, for: item)
            } catch {
                errorMessage = error.localizedDescription
            }
            item.isGeneratingAI = false
        }
    }

    private func optimizeDefinition() {
        guard let def = firstDefinition else { return }

        item.isGeneratingAI = true
        errorMessage = nil

        Task {
            do {
                let optimized = try await llmService.optimizeDefinition(
                    word: item.word,
                    rawDefinition: def
                )
                viewModel.saveAIDefinitionNote(optimized, for: item)
            } catch {
                errorMessage = error.localizedDescription
            }
            item.isGeneratingAI = false
        }
    }

    // MARK: - Helpers

    private var firstDefinition: String? {
        guard let result = item.lookupResult else { return nil }
        return firstSenseInfo(from: result)?.1
    }

    private func firstSenseInfo(from result: LookupResult) -> (String, String)? {
        for entry in result.entries {
            for lexical in entry.lexicalEntries {
                for sense in lexical.senses {
                    let def = sense.definition
                    if !def.isEmpty {
                        return (lexical.partOfSpeech.rawValue, def)
                    }
                }
            }
        }
        return nil
    }
}
