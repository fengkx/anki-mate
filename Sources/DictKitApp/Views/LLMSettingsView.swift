import SwiftUI
import AnkiMateLLM
import AnkiMateRPC

struct LLMSettingsView: View {
    @EnvironmentObject private var llmService: LLMService
    @Environment(\.dismiss) private var dismiss

    @State private var isTogglingServer = false
    @AppStorage(LLMDebugSettings.streamDebugEnabledKey) private var streamDebugEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overviewSection
                    if let notice = llmService.downloadManager.latestNotice {
                        noticeBanner(notice)
                    }
                    mirrorSection
                    debugSection
                    modelListSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Model Settings")
                    .font(.title3.weight(.semibold))
                Text("Manage local models, server state, and download behavior for on-device LLM features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSection: some View {
        HStack(alignment: .top, spacing: 12) {
            settingsCard(title: "Inference Server", subtitle: serverStatusSummary) {
                HStack(alignment: .center, spacing: 10) {
                    StatusPulseDot(color: serverStatusColor, isPulsing: shouldPulseServerStatus)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(serverStatusText)
                            .font(.body.weight(.medium))
                        Text(serverActionHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    serverActionButton
                }
            }

            settingsCard(title: "Selected Model", subtitle: selectedModelSummary) {
                if let selectedModel = selectedModel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(selectedModel.displayName)
                                .font(.body.weight(.medium))
                            if llmService.loadedModelId == selectedModel.id {
                                statusBadge(text: "Active", tint: .green)
                            } else if llmService.downloadManager.isDownloaded(selectedModel) {
                                statusBadge(text: "Downloaded", tint: .blue)
                            } else {
                                statusBadge(text: "Not downloaded", tint: .secondary)
                            }
                        }

                        Text("\(selectedModel.quantization) · \(selectedModel.formattedSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Select a local model to enable AI generation in the assistant panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Mirror

    @ViewBuilder
    private var mirrorSection: some View {
        settingsCard(title: "Download Source", subtitle: "Optional HuggingFace mirror") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    let binding = Binding<String>(
                        get: { llmService.downloadManager.hfMirror },
                        set: { llmService.downloadManager.hfMirror = $0 }
                    )

                    TextField("hf-mirror.com", text: binding)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())

                    if !llmService.downloadManager.hfMirror.isEmpty {
                        Button("Clear") {
                            llmService.downloadManager.hfMirror = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text("Leave empty to use huggingface.co directly. Use a mirror only when downloads are slow or blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        settingsCard(title: "Debug", subtitle: "Streaming diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable streaming debug logs", isOn: $streamDebugEnabled)
                Text("When enabled, stream chunk diagnostics are written to app logs (RPCClient category).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Notice

    @ViewBuilder
    private func noticeBanner(_ notice: ModelDownloadManager.DownloadNotice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notice.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(notice.kind == .success ? .green : .orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            noticeActions(notice)

            Button {
                llmService.downloadManager.dismissLatestNotice()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(notice.kind == .success ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(notice.kind == .success ? Color.green.opacity(0.28) : Color.orange.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - Model List

    @ViewBuilder
    private var modelListSection: some View {
        settingsCard(title: "Available Models", subtitle: "Download and manage local GGUF weights") {
            VStack(spacing: 12) {
                if llmService.registry.models.isEmpty {
                    Text("No models available")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(llmService.registry.models) { model in
                        modelRow(model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(.body.weight(.medium))

                        if model.recommended {
                            statusBadge(text: "Recommended", tint: .blue)
                        }
                    }

                    Text("\(model.quantization) · \(model.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                modelStatusBadge(model)
            }

            if let progress = llmService.downloadManager.downloads[model.id] {
                modelProgressBlock(model, progress: progress)
            } else if llmService.downloadManager.isDeleting(modelId: model.id) {
                deletingProgressBlock
            }

            HStack(spacing: 8) {
                modelActions(model)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(rowBorderColor(for: model), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func modelStatusBadge(_ model: ModelInfo) -> some View {
        if llmService.downloadManager.isDeleting(modelId: model.id) {
            statusBadge(text: "Removing", tint: .orange)
        } else if llmService.loadedModelId == model.id {
            statusBadge(text: "Active", tint: .green)
        } else if llmService.selectedModelId == model.id, llmService.downloadManager.isDownloaded(model) {
            statusBadge(text: "Selected", tint: .blue)
        } else if llmService.downloadManager.isDownloaded(model) {
            statusBadge(text: "Downloaded", tint: .secondary)
        } else if let progress = llmService.downloadManager.downloads[model.id] {
            switch progress.state {
            case .downloading:
                statusBadge(text: "Downloading", tint: .blue)
            case .paused:
                statusBadge(text: "Paused", tint: .orange)
            case .completed:
                statusBadge(text: "Ready", tint: .secondary)
            case .failed:
                statusBadge(text: "Needs attention", tint: .orange)
            }
        } else {
            statusBadge(text: "Not downloaded", tint: .secondary)
        }
    }

    @ViewBuilder
    private func modelProgressBlock(_ model: ModelInfo, progress: ModelDownloadManager.DownloadProgress) -> some View {
        switch progress.state {
        case .downloading:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fractionCompleted)
                    .tint(.blue)
                HStack {
                    Text(progress.formattedProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(progress.transferStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .paused:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fractionCompleted)
                    .tint(.orange)
                Text("Paused · \(progress.formattedProgress)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Download interrupted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let suggestion = progress.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .completed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var deletingProgressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Removing local model files...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This model will disappear from the list when deletion finishes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func modelActions(_ model: ModelInfo) -> some View {
        let dm = llmService.downloadManager

        if dm.isDeleting(modelId: model.id) {
            Text("Removing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if dm.isDownloaded(model) {
            downloadedActions(model)
        } else if let progress = dm.downloads[model.id] {
            switch progress.state {
            case .downloading:
                Button("Pause") {
                    dm.pause(modelId: model.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Cancel", role: .destructive) {
                    dm.cancel(modelId: model.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .paused:
                Button("Resume") {
                    dm.download(model: model)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel", role: .destructive) {
                    dm.cancel(modelId: model.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .completed:
                downloadedActions(model)
            case .failed:
                Button(dm.canResume(modelId: model.id) ? "Resume" : "Retry") {
                    dm.download(model: model)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if shouldOfferMirrorShortcut(for: model.id) {
                    Button("Use Mirror") {
                        dm.hfMirror = "hf-mirror.com"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            Button("Download") {
                dm.download(model: model)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func downloadedActions(_ model: ModelInfo) -> some View {
        if llmService.downloadManager.isDeleting(modelId: model.id) {
            Text("Removing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if llmService.selectedModelId == model.id {
                Button("Selected") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
            } else {
                Button("Select") {
                    llmService.selectedModelId = model.id
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button("Delete", role: .destructive) {
                Task { @MainActor in
                    if llmService.loadedModelId == model.id {
                        await llmService.stopServer()
                    }
                    if llmService.selectedModelId == model.id {
                        llmService.selectedModelId = ""
                    }
                    try? await llmService.downloadManager.deleteModel(model)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverActionButton: some View {
        switch llmService.serverState {
        case .running:
            Button("Stop") {
                toggleServer(start: false)
            }
            .buttonStyle(.bordered)
            .disabled(isTogglingServer)
        case .stopped, .failed:
            Button("Start") {
                toggleServer(start: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTogglingServer)
        case .starting:
            Button("Starting...") {}
                .buttonStyle(.bordered)
                .disabled(true)
        }
    }

    private func toggleServer(start: Bool) {
        guard !isTogglingServer else { return }
        isTogglingServer = true
        Task { @MainActor in
            if start {
                await llmService.startServer()
            } else {
                await llmService.stopServer()
            }
            isTogglingServer = false
        }
    }

    private var serverStatusColor: Color {
        switch llmService.serverState {
        case .running: return .green
        case .starting: return .blue
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var shouldPulseServerStatus: Bool {
        switch llmService.serverState {
        case .starting, .running:
            return true
        case .stopped, .failed:
            return false
        }
    }

    private var serverStatusText: String {
        switch llmService.serverState {
        case .running(let port): return "Running on port \(port)"
        case .starting: return "Starting..."
        case .stopped: return "Stopped"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    private var serverStatusSummary: String {
        switch llmService.serverState {
        case .running:
            return "The local inference server is ready for requests."
        case .starting:
            return "Launching the background process."
        case .stopped:
            return "Start the server before running AI generation."
        case .failed:
            return "The server needs attention before it can serve requests."
        }
    }

    private var serverActionHint: String {
        switch llmService.serverState {
        case .running:
            return "You can keep it running while reviewing or generating AI content."
        case .starting:
            return "This usually takes a few seconds."
        case .stopped:
            return "The first AI request can also start the server lazily."
        case .failed:
            return "Check logs or switch to a downloaded model and retry."
        }
    }

    private var selectedModel: ModelInfo? {
        llmService.registry.models.first(where: { $0.id == llmService.selectedModelId })
    }

    private var selectedModelSummary: String {
        if selectedModel != nil {
            return "Downloaded and ready to select or use."
        }
        return "No model selected yet."
    }

    // MARK: - Notice helpers

    @ViewBuilder
    private func noticeActions(_ notice: ModelDownloadManager.DownloadNotice) -> some View {
        switch notice.kind {
        case .success:
            if let model = llmService.registry.models.first(where: { $0.id == notice.modelId }),
               llmService.selectedModelId != model.id,
               llmService.downloadManager.isDownloaded(model) {
                Button("Select") {
                    llmService.selectedModelId = model.id
                    llmService.downloadManager.dismissLatestNotice()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .error:
            if let model = llmService.registry.models.first(where: { $0.id == notice.modelId }) {
                Button(llmService.downloadManager.canResume(modelId: model.id) ? "Resume" : "Retry") {
                    llmService.downloadManager.download(model: model)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if shouldOfferMirrorShortcut(for: model.id) {
                    Button("Use Mirror") {
                        llmService.downloadManager.hfMirror = "hf-mirror.com"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func shouldOfferMirrorShortcut(for modelId: String) -> Bool {
        guard llmService.downloadManager.hfMirror.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let progress = llmService.downloadManager.downloads[modelId],
              let suggestion = progress.recoverySuggestion?.lowercased() else {
            return false
        }
        return suggestion.contains("mirror")
    }

    private func rowBorderColor(for model: ModelInfo) -> Color {
        if llmService.loadedModelId == model.id {
            return .green.opacity(0.28)
        }
        if llmService.selectedModelId == model.id {
            return .blue.opacity(0.24)
        }
        return .white.opacity(0.06)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func statusBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
