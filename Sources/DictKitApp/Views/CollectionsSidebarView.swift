import SwiftUI

struct CollectionsSidebarView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @Binding var collectionEditorMode: CollectionEditorMode?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Collections")
                    .font(.headline)

                Spacer()

                Button {
                    collectionEditorMode = .create
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("New collection")
            }
            .padding()

            List(selection: $viewModel.currentCollectionID) {
                ForEach(viewModel.collections) { collection in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                            .font(.body.weight(.medium))
                        Text("\(viewModel.exportableWordCount(for: collection.id)) ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(collection.id)
                    .contextMenu {
                        Button("Rename") {
                            viewModel.selectCollection(id: collection.id)
                            collectionEditorMode = .rename
                        }

                        Button("Delete", role: .destructive) {
                            viewModel.selectCollection(id: collection.id)
                            viewModel.deleteCurrentCollection()
                        }
                        .disabled(viewModel.collections.count <= 1)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}
