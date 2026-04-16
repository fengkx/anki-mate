import SwiftUI

struct ExportProgressView: View {
    @EnvironmentObject var viewModel: WordListViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Exporting to Anki...")
                .font(.headline)

            ProgressView(value: viewModel.exportProgress)
                .progressViewStyle(.linear)

            Text("\(Int(viewModel.exportProgress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .frame(width: 300)
    }
}
