import SwiftUI
import AnkiMateLLM

struct CollectionsSidebarView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @EnvironmentObject var syncStatus: SyncStatus
    @EnvironmentObject var llmService: LLMService
    @Binding var collectionEditorMode: CollectionEditorMode?
    @State private var showSyncSettings = false
    @State private var showLLMSettings = false
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

            // Sync status button
            Button {
                showSyncSettings = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(syncStatusColor)
                        .frame(width: 8, height: 8)
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

            // AI Model button — shows download progress when active
            Button {
                showLLMSettings = true
            } label: {
                aiModelButtonContent
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("AI model settings")
            .sheet(isPresented: $showLLMSettings) {
                LLMSettingsView()
            }
        }
    }

    // MARK: - AI Model Button

    @ViewBuilder
    private var aiModelButtonContent: some View {
        if let summary = llmService.downloadManager.activeDownloadSummary {
            // Show download progress inline
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text(summary.modelName)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int(summary.fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: summary.fraction)
                    .controlSize(.mini)
            }
        } else if hasPausedDownload {
            // Show paused indicator
            HStack(spacing: 6) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Download Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            // Default state
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(llmService.serverState.isRunning ? .green : .secondary)
                Text("AI Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var hasPausedDownload: Bool {
        llmService.downloadManager.downloads.values.contains { $0.state == .paused }
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
