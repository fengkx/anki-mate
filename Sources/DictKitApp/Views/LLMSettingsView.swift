import SwiftUI
import AnkiMateLLM
import AnkiMateRPC

struct LLMSettingsView: View {
    @EnvironmentObject private var llmService: LLMService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Model Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    mirrorSection
                    serverStatusSection
                    modelListSection
                }
                .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    // MARK: - HF Mirror

    @ViewBuilder
    private var mirrorSection: some View {
        GroupBox("HuggingFace Mirror") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    let binding = Binding<String>(
                        get: { llmService.downloadManager.hfMirror },
                        set: { llmService.downloadManager.hfMirror = $0 }
                    )
                    TextField("hf-mirror.com", text: binding)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())

                    if !llmService.downloadManager.hfMirror.isEmpty {
                        Button {
                            llmService.downloadManager.hfMirror = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Text("Leave empty to use huggingface.co directly. Common mirrors: hf-mirror.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Server Status

    @ViewBuilder
    private var serverStatusSection: some View {
        GroupBox("Inference Server") {
            HStack {
                Circle()
                    .fill(serverStatusColor)
                    .frame(width: 8, height: 8)
                Text(serverStatusText)
                    .font(.subheadline)
                Spacer()

                if llmService.serverState.isRunning {
                    Button("Stop") {
                        Task { await llmService.stopServer() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var serverStatusColor: Color {
        switch llmService.serverState {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .failed: return .red
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

    // MARK: - Model List

    @ViewBuilder
    private var modelListSection: some View {
        GroupBox("Available Models") {
            VStack(spacing: 8) {
                ForEach(llmService.registry.models) { model in
                    modelRow(model)
                    if model.id != llmService.registry.models.last?.id {
                        Divider()
                    }
                }

                if llmService.registry.models.isEmpty {
                    Text("No models available")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.body)
                    if model.recommended {
                        Text("Recommended")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .clipShape(Capsule())
                    }
                }
                Text("\(model.quantization) \u{00B7} \(model.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            modelActions(model)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelActions(_ model: ModelInfo) -> some View {
        let dm = llmService.downloadManager

        if dm.isDownloaded(model) {
            downloadedActions(model)
        } else if let progress = dm.downloads[model.id] {
            switch progress.state {
            case .downloading:
                downloadingView(model, progress: progress)
            case .paused:
                pausedView(model, progress: progress)
            case .completed:
                downloadedActions(model)
            case .failed(let msg):
                failedView(model, message: msg)
            }
        } else {
            Button("Download") {
                dm.download(model: model)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - State Views

    @ViewBuilder
    private func downloadingView(_ model: ModelInfo, progress: ModelDownloadManager.DownloadProgress) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: progress.fractionCompleted)
                    .frame(width: 100)
                Text(progress.formattedProgress)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("\(Int(progress.fractionCompleted * 100))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
            // Pause button
            Button {
                llmService.downloadManager.pause(modelId: model.id)
            } label: {
                Image(systemName: "pause.circle")
            }
            .buttonStyle(.borderless)
            .help("Pause download")
            // Cancel button
            Button {
                llmService.downloadManager.cancel(modelId: model.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .help("Cancel download")
        }
    }

    @ViewBuilder
    private func pausedView(_ model: ModelInfo, progress: ModelDownloadManager.DownloadProgress) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: progress.fractionCompleted)
                    .frame(width: 100)
                    .tint(.orange)
                Text("Paused \u{00B7} \(progress.formattedProgress)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
            // Resume button
            Button {
                llmService.downloadManager.download(model: model)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.blue)
            .help("Resume download")
            // Cancel button
            Button {
                llmService.downloadManager.cancel(modelId: model.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .help("Cancel download")
        }
    }

    @ViewBuilder
    private func failedView(_ model: ModelInfo, message: String) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Failed")
                    .foregroundColor(.red)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 180)
            }
            // Retry / Resume
            Button {
                llmService.downloadManager.download(model: model)
            } label: {
                let canResume = llmService.downloadManager.canResume(modelId: model.id)
                Text(canResume ? "Resume" : "Retry")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func downloadedActions(_ model: ModelInfo) -> some View {
        HStack(spacing: 8) {
            if llmService.selectedModelId == model.id {
                Text("Active")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button("Select") {
                    llmService.selectedModelId = model.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                try? llmService.downloadManager.deleteModel(model)
                if llmService.selectedModelId == model.id {
                    llmService.selectedModelId = ""
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
        }
    }
}
