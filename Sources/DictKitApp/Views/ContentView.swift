import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @State private var collectionEditorMode: CollectionEditorMode?

    var body: some View {
        NavigationSplitView {
            CollectionsSidebarView(collectionEditorMode: $collectionEditorMode)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            WordsColumnView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
        } detail: {
            if let selected = viewModel.selectedWord {
                CardPreviewView(item: selected)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Select a word to preview its Anki card")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .sheet(isPresented: $viewModel.showBatchInput) {
            BatchInputSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showExportDialog) {
            ExportCollectionsSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isExporting) {
            ExportProgressView()
                .environmentObject(viewModel)
        }
        .sheet(item: $collectionEditorMode) { mode in
            CollectionEditorSheet(
                mode: mode,
                initialName: mode == .rename ? (viewModel.currentCollection?.name ?? "") : ""
            ) { name in
                switch mode {
                case .create:
                    return viewModel.createCollection(named: name)
                case .rename:
                    return viewModel.renameCurrentCollection(to: name)
                }
            }
            .environmentObject(viewModel)
        }
        .confirmationDialog(
            "Delete Word",
            isPresented: Binding(
                get: { viewModel.pendingWordDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelPendingWordDeletion()
                    }
                }
            ),
            presenting: viewModel.pendingWordDeletion
        ) { pendingWordDeletion in
            Button("Remove from \(pendingWordDeletion.currentCollectionName)", role: .destructive) {
                viewModel.confirmRemovePendingWordFromCurrentCollection()
            }

            Button("Delete Everywhere", role: .destructive) {
                viewModel.confirmDeletePendingWordEverywhere()
            }

            Button("Cancel", role: .cancel) {
                viewModel.cancelPendingWordDeletion()
            }
        } message: { pendingWordDeletion in
            if pendingWordDeletion.otherCollectionNames.isEmpty {
                Text("This word only exists in \(pendingWordDeletion.currentCollectionName).")
            } else {
                Text("Also in: \(pendingWordDeletion.otherCollectionNames.joined(separator: ", "))")
            }
        }
        .alert("Export Result", isPresented: .init(
            get: { viewModel.exportError != nil && !viewModel.isExporting },
            set: { if !$0 { viewModel.exportError = nil } }
        )) {
            Button("OK") { viewModel.exportError = nil }
        } message: {
            Text(viewModel.exportError ?? "")
        }
    }
}

enum CollectionEditorMode: String, Identifiable {
    case create
    case rename

    var id: String { rawValue }
}
