import SwiftUI

struct CollectionsSidebarView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @EnvironmentObject var syncStatus: SyncStatus
    @Binding var collectionEditorMode: CollectionEditorMode?
    @State private var showSyncSettings = false
    var onSyncNow: (() async -> Void)?
    var onIntervalChanged: ((SyncInterval) -> Void)?

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

            Divider()

            Button {
                showSyncSettings = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: syncStatus.systemImage)
                        .foregroundStyle(syncStatusColor)
                    Text(syncStatus.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("Sync settings")
            .sheet(isPresented: $showSyncSettings) {
                SyncSettingsView(onSyncNow: onSyncNow, onIntervalChanged: onIntervalChanged)
            }
        }
    }

    private var syncStatusColor: Color {
        switch syncStatus.state {
        case .idle:
            if syncStatus.hasPendingChanges { return .orange }
            return syncStatus.isConfigured ? .green : .secondary
        case .syncing:
            return .blue
        case .error:
            return .red
        }
    }
}
