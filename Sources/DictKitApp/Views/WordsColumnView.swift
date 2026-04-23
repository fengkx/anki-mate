import SwiftUI

struct WordsColumnView: View {
    @EnvironmentObject var viewModel: WordListViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.wordsColumnTitle)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(viewModel.wordsColumnCardSummary)
                            Text(viewModel.wordsColumnReadySummary)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    }
                    .layoutPriority(0)

                    Spacer(minLength: 8)

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
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
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
