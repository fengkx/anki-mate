import SwiftUI
import AnkiMateLLM

struct CollectionsSidebarView: View {
    @EnvironmentObject var viewModel: WordListViewModel
    @EnvironmentObject var syncStatus: SyncStatus
    @EnvironmentObject var llmService: LLMService
    @Environment(\.openWindow) private var openWindow
    @Binding var collectionEditorMode: CollectionEditorMode?
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
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(collection.name)
                                .font(.body.weight(.medium))
                            Text("\(viewModel.exportableWordCount(for: collection.id)) ready")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if viewModel.currentCollectionID == collection.id {
                            Button {
                                viewModel.selectCollection(id: collection.id)
                                collectionEditorMode = .rename
                            } label: {
                                Image(systemName: "book.closed")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Collection settings")
                        }
                    }
                    .tag(collection.id)
                    .contextMenu {
                        Button("Collection Settings") {
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

            VStack(spacing: 0) {
                utilityBarButton(
                    title: syncStatusLabel,
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: syncStatusColor,
                    helpText: "Sync settings"
                ) {
                    openWindow(id: AppWindowIDs.syncSettings)
                }

                Divider()
                    .padding(.leading, 12)

                Button {
                    openWindow(id: AppWindowIDs.aiSettings)
                } label: {
                    aiModelButtonContent
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .hoverCursor()
                .help("AI settings")

                Divider()
                    .padding(.leading, 12)

                utilityBarButton(
                    title: "Help",
                    systemImage: "questionmark.circle",
                    tint: .secondary,
                    helpText: "Help"
                ) {
                    openWindow(id: AppWindowIDs.help)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        }
    }

    // MARK: - AI Model Button

    @ViewBuilder
    private var aiModelButtonContent: some View {
        if let summary = llmService.downloadManager.activeDownloadSummary {
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
                Text(summary.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                ProgressView(value: summary.fraction)
                    .controlSize(.mini)
            }
        } else if hasPausedDownload {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Download paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if let notice = llmService.downloadManager.latestNotice {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: notice.kind == .success ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(notice.kind == .success ? .green : .orange)
                        .font(.caption)
                    Text(notice.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                }
                Text(notice.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                StatusPulseDot(color: serverStatusColor, isPulsing: shouldPulseServerStatus)
                Text(serverStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var hasPausedDownload: Bool {
        llmService.downloadManager.downloads.values.contains { $0.state == .paused }
    }

    private var serverStatusLabel: String {
        switch llmService.serverState {
        case .running:
            return "AI is ready"
        case .starting:
            return "Starting AI"
        case .stopped:
            return "Set up AI"
        case .failed:
            return "AI needs attention"
        }
    }

    private var syncStatusLabel: String {
        switch syncStatus.state {
        case .idle:
            if syncStatus.hasPendingChanges {
                return "Sync available"
            }
            return syncStatus.isConfigured ? "Sync is on" : "Set up sync"
        case .syncing:
            return "Syncing"
        case .error:
            return "Sync needs attention"
        }
    }

    private var serverStatusColor: Color {
        switch llmService.serverState {
        case .running:
            return .green
        case .starting:
            return .blue
        case .stopped:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var shouldPulseServerStatus: Bool {
        llmService.serverState.shouldPulseStatusIndicator
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

    private func utilityBarButton(
        title: String,
        systemImage: String,
        tint: Color,
        helpText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .hoverCursor()
        .help(helpText)
    }
}
