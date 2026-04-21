import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @EnvironmentObject var helpCenter: HelpCenterState
    @EnvironmentObject var commandPalette: CommandPaletteViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var collectionEditorMode: CollectionEditorMode?
    var onSyncNow: (() async -> Void)?
    var onIntervalChanged: ((SyncInterval) -> Void)?

    var body: some View {
        NavigationSplitView {
            CollectionsSidebarView(collectionEditorMode: $collectionEditorMode, onSyncNow: onSyncNow, onIntervalChanged: onIntervalChanged)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            WordsColumnView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
        } detail: {
            if let selected = viewModel.selectedWord {
                CardPreviewView(item: selected)
                    .id(selected.id)
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
        .overlay {
            CommandPaletteView()
                .environmentObject(commandPalette)
        }
        .sheet(isPresented: $viewModel.showBatchInput) {
            BatchInputSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showExportDialog) {
            ExportCollectionsSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $helpCenter.isGuidePresented) {
            HelpGuideView()
                .environmentObject(helpCenter)
        }
        .sheet(isPresented: $viewModel.isExporting) {
            ExportProgressView()
                .environmentObject(viewModel)
        }
        .sheet(item: $collectionEditorMode) { mode in
            CollectionEditorSheet(
                mode: mode,
                initialForm: viewModel.collectionEditorForm(for: mode)
            ) { form in
                switch mode {
                case .create:
                    return viewModel.createCollection(using: form)
                case .rename, .dictionary:
                    return viewModel.renameCurrentCollection(using: form)
                }
            }
            .environmentObject(viewModel)
        }
        .alert("Export Result", isPresented: .init(
            get: { viewModel.exportError != nil && !viewModel.isExporting },
            set: { if !$0 { viewModel.exportError = nil } }
        )) {
            Button("OK") { viewModel.exportError = nil }
        } message: {
            Text(viewModel.exportError ?? "")
        }
        .alert("Storage Error", isPresented: .init(
            get: { viewModel.storeErrorMessage != nil },
            set: { if !$0 { viewModel.dismissStoreError() } }
        )) {
            Button("OK") { viewModel.dismissStoreError() }
        } message: {
            Text(viewModel.storeErrorMessage ?? "")
        }
        .onAppear {
            commandPalette.configure(actions: .init(
                openBatchAdd: { viewModel.showBatchInput = true },
                openExport: { viewModel.showExportDialog = true },
                openNewCollection: { collectionEditorMode = .create },
                openCollectionSettings: { collectionEditorMode = .rename },
                openWindow: { openWindow(id: $0) },
                syncNow: {
                    if let onSyncNow {
                        await onSyncNow()
                    }
                }
            ))
        }
    }
}

enum CollectionEditorMode: String, Identifiable {
    case create
    case rename
    case dictionary

    var id: String { rawValue }
}
