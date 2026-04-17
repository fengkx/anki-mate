import SwiftUI

struct WordsColumnView: View {
    @EnvironmentObject var viewModel: WordListViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.wordsColumnTitle)
                            .font(.title2.weight(.semibold))
                        Text(viewModel.wordsColumnSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button("Batch Add") {
                            viewModel.showBatchInput = true
                        }
                        .buttonStyle(.bordered)

                        Button("Export to Anki") {
                            viewModel.showExportDialog = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.canExportCurrentCollection)
                    }
                }

                WordInputView()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            WordListView()
        }
    }
}
