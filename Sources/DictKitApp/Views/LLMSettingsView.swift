import SwiftUI
import AnkiMateLLM
import AnkiMateRPC

private extension LLMContentStyle {
    var title: String {
        switch self {
        case .steadier:
            return "Steadier"
        case .balanced:
            return "Balanced"
        case .moreVaried:
            return "More varied"
        }
    }

    var caption: String {
        switch self {
        case .steadier:
            return "Often a better fit for more consistent wording."
        case .balanced:
            return "A middle ground for most study tasks."
        case .moreVaried:
            return "Can feel more flexible, especially for creative phrasing."
        }
    }

}

struct LLMSettingsView: View {
    @EnvironmentObject private var llmService: LLMService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var serverControls = LLMServerControlsModel()
    @AppStorage(LLMDebugSettings.streamDebugEnabledKey) private var streamDebugEnabled = false
    @AppStorage(LLMContentStyle.defaultsKey) private var storedContentStyle = LLMContentStyle.balanced.rawValue

    private var serverGuidance: LLMServerStatusGuidance {
        LLMServerStatusGuidance.make(
            for: llmService.serverState,
            hasModel: llmService.hasModel
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overviewSection
                    contentStyleSection
                    if let notice = llmService.downloadManager.latestNotice {
                        noticeBanner(notice)
                    }
                    modelListSection
                    optionsSection
                }
                .padding(20)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI")
                    .font(.title3.weight(.semibold))
                Text("Set up local AI features and downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSection: some View {
        HStack(alignment: .top, spacing: 12) {
            primaryOverviewCard
            secondaryOverviewCard
        }
    }

    @ViewBuilder
    private var primaryOverviewCard: some View {
        settingsCard(
            title: "Local AI",
            subtitle: serverStatusSummary,
            tone: serverCardTone,
            minHeight: 176
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    serverStatusSummaryBlock
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    serverActionButtons
                        .fixedSize()
                        .padding(.top, 4)
                }

                serverEndpointPanel

                if shouldShowServerDiagnosticsActions {
                    serverDiagnosticsActions
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryOverviewCard: some View {
        settingsCard(
            title: "Current Model",
            subtitle: selectedModelSummary,
            tone: .neutral,
            minHeight: 176
        ) {
            if let selectedModel = selectedModel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(selectedModel.displayName)
                            .font(.headline)
                            .lineLimit(1)

                        if selectedModel.recommended {
                            statusBadge(text: "Recommended", tint: .blue)
                        }

                        if llmService.selectedModelId == selectedModel.id,
                           llmService.downloadManager.isDownloaded(selectedModel) {
                            statusBadge(text: "Selected", tint: .blue)
                        }
                    }

                    Text("\(selectedModel.quantization) · \(selectedModel.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("A model can be selected after it finishes downloading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Content Style

    @ViewBuilder
    private var contentStyleSection: some View {
        settingsCard(
            title: "Content Style",
            subtitle: "This setting applies across local AI features.",
            tone: .neutral
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    contentStyleSummary
                        .frame(maxWidth: .infinity, alignment: .leading)
                    contentStylePicker
                        .frame(width: 300)
                }

                VStack(alignment: .leading, spacing: 8) {
                    contentStylePicker
                    contentStyleSummary
                }
            }
        }
    }

    private var contentStyleSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(contentStyle.title)
                .font(.subheadline.weight(.semibold))
            Text(contentStyle.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contentStylePicker: some View {
        Picker("Content Style", selection: contentStyleBinding) {
            ForEach(LLMContentStyle.allCases, id: \.rawValue) { style in
                Text(style.title).tag(style)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.regular)
    }

    // MARK: - Mirror

    @ViewBuilder
    private var mirrorSection: some View {
        settingsCard(title: "Download Source", subtitle: "Optional mirror", tone: .neutral) {
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

                Text("Leave this empty unless you need a mirror for downloads.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        settingsCard(title: "Debug", subtitle: "Advanced logs", tone: .neutral) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable debug logs", isOn: $streamDebugEnabled)
                Text("Writes detailed AI traces to /tmp/anki-mate-llm-debug.jsonl.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        settingsCard(title: "More Options", subtitle: "Optional download and troubleshooting settings", tone: .neutral) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    mirrorSectionBody
                    debugSectionBody
                }

                VStack(alignment: .leading, spacing: 14) {
                    mirrorSectionBody
                    debugSectionBody
                }
            }
        }
    }

    private var mirrorSectionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download Source")
                .font(.subheadline.weight(.semibold))
            mirrorControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var debugSectionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug")
                .font(.subheadline.weight(.semibold))
            debugControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mirrorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
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

            Text("Leave this empty unless you need a mirror for downloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var debugControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable debug logs", isOn: $streamDebugEnabled)
            Text("Writes detailed AI traces to /tmp/anki-mate-llm-debug.jsonl.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(12)
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
        settingsCard(title: "Available Models", subtitle: "Download and manage local models", tone: .neutral) {
            VStack(spacing: 0) {
                if llmService.registry.models.isEmpty {
                    Text("No models available")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    modelListHeader
                    ForEach(llmService.registry.models) { model in
                        modelRow(model)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        if model.recommended {
                            statusBadge(text: "Recommended", tint: .blue)
                        }
                        if model.supportsVision {
                            statusBadge(text: "Vision", tint: .green)
                        }
                    }

                    Text("\(model.quantization) · \(model.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                modelStatusBadge(model)
                    .frame(width: 120, alignment: .trailing)

                HStack(spacing: 8) {
                    modelActions(model)
                }
                .frame(width: 170, alignment: .trailing)
            }

            if let progress = llmService.downloadManager.downloads[model.id] {
                modelProgressBlock(model, progress: progress)
            } else if llmService.downloadManager.isDeleting(modelId: model.id) {
                deletingProgressBlock
            } else if llmService.downloadManager.localAssetState(for: model) == .missingMMProj {
                missingProjectorBlock
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(rowBorderColor(for: model))
                .frame(height: 1)
        }
    }

    private var modelListHeader: some View {
        HStack(spacing: 12) {
            Text("Model")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Status")
                .frame(width: 120, alignment: .trailing)

            Text("Actions")
                .frame(width: 170, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
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
        } else if llmService.downloadManager.localAssetState(for: model) == .missingMMProj {
            statusBadge(text: "Missing projector", tint: .orange)
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
                actionButton("Pause") {
                    dm.pause(modelId: model.id)
                }

                actionButton("Cancel", role: .destructive) {
                    dm.cancel(modelId: model.id)
                }
            case .paused:
                actionButton("Resume", prominent: true) {
                    dm.download(model: model)
                }

                actionButton("Cancel", role: .destructive) {
                    dm.cancel(modelId: model.id)
                }
            case .completed:
                downloadedActions(model)
            case .failed:
                actionButton(dm.canResume(modelId: model.id) ? "Resume" : "Retry", prominent: true) {
                    dm.download(model: model)
                }

                if shouldOfferMirrorShortcut(for: model.id) {
                    actionButton("Use Mirror") {
                        dm.hfMirror = "hf-mirror.com"
                    }
                }
            }
        } else {
            actionButton(dm.downloadActionTitle(for: model), prominent: true) {
                dm.download(model: model)
            }
        }
    }

    private var missingProjectorBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Vision projector missing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("The main model file is present, but image input needs the companion mmproj file. Download the projector to enable attachments with images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func downloadedActions(_ model: ModelInfo) -> some View {
        if llmService.downloadManager.isDeleting(modelId: model.id) {
            Text("Removing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if llmService.selectedModelId != model.id {
            actionButton("Select", prominent: true) {
                llmService.selectedModelId = model.id
            }
        }

        if !llmService.downloadManager.isDeleting(modelId: model.id) {
            actionButton("Delete", role: .destructive) {
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
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverActionButtons: some View {
        if !llmService.hasModel {
            EmptyView()
        } else {
        switch llmService.serverState {
        case .running:
            HStack(spacing: 6) {
                serverControlButton(
                    title: serverGuidance.actionButtonTitle,
                    isLoading: serverControls.isStopping,
                    prominent: false,
                    disabled: serverControls.isBusy
                ) {
                    Task { @MainActor in
                        await serverControls.performStop(using: llmService)
                    }
                }

                serverControlButton(
                    title: "Restart",
                    isLoading: serverControls.isRestarting,
                    prominent: false,
                    disabled: serverControls.isBusy
                ) {
                    Task { @MainActor in
                        try? await serverControls.performRestart(using: llmService)
                    }
                }
            }
        case .stopped, .failed:
            serverControlButton(
                title: serverGuidance.actionButtonTitle,
                isLoading: serverControls.isStarting,
                prominent: true,
                disabled: serverControls.isBusy
            ) {
                Task { @MainActor in
                    await serverControls.performStart(using: llmService)
                }
            }
        case .starting:
            serverControlButton(
                title: serverGuidance.actionButtonTitle,
                isLoading: true,
                prominent: false,
                disabled: true,
                action: {}
            )
        }
        }
    }

    private var serverStatusSummaryBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusPulseDot(color: serverStatusColor, isPulsing: shouldPulseServerStatus)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(serverStatusText)
                    .font(.headline)

                Text(serverActionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var serverEndpointPanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                ForEach(serverEndpointRows, id: \.label) { endpoint in
                    serverEndpointPill(endpoint)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(serverEndpointRows, id: \.label) { endpoint in
                    serverEndpointPill(endpoint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serverEndpointRows: [LLMServerStatusDisplay.Endpoint] {
        LLMServerStatusDisplay.endpoints(
            ankimateServerPort: llmService.serverState.port,
            llamaServerPort: llmService.llamaServerPort
        )
    }

    private func serverEndpointPill(_ endpoint: LLMServerStatusDisplay.Endpoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(endpoint.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(endpoint.value)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(endpoint.isAvailable ? Color.primary.opacity(0.72) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
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
        llmService.serverState.shouldPulseStatusIndicator
    }

    private var serverStatusText: String {
        serverGuidance.statusText
    }

    private var shouldShowServerDiagnosticsActions: Bool {
        if case .failed = llmService.serverState {
            return true
        }
        return false
    }

    private var serverStatusSummary: String {
        serverGuidance.summary
    }

    private var serverActionHint: String {
        serverGuidance.actionHint
    }

    @ViewBuilder
    private var serverDiagnosticsActions: some View {
        Button("Copy Diagnostics") {
            LLMServerDiagnostics.copyDiagnostics(service: llmService)
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.top, 2)
    }

    private var selectedModel: ModelInfo? {
        llmService.registry.models.first(where: { $0.id == llmService.selectedModelId })
    }

    private var selectedModelSummary: String {
        if selectedModel != nil {
            return "This model is currently selected for local AI features."
        }
        if !llmService.hasModel {
            return "Download and select a model to set up local AI features."
        }
        return "A model can be selected after it finishes downloading."
    }

    private var contentStyle: LLMContentStyle {
        get { LLMContentStyle(rawValue: storedContentStyle) ?? .balanced }
        nonmutating set { storedContentStyle = newValue.rawValue }
    }

    private var contentStyleBinding: Binding<LLMContentStyle> {
        Binding(
            get: { contentStyle },
            set: { contentStyle = $0 }
        )
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
            return .green.opacity(0.18)
        }
        if llmService.selectedModelId == model.id {
            return .blue.opacity(0.16)
        }
        return Color.primary.opacity(0.06)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        tone: SettingsCardTone,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(12)
        .frame(minHeight: minHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(cardBackground(for: tone))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(cardBorder(for: tone), lineWidth: 1)
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

    private func actionButton(
        _ title: String,
        prominent: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if prominent {
                Button(title, role: role, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title, role: role, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .frame(minWidth: 76)
    }

    private func serverControlButton(
        title: String,
        isLoading: Bool,
        prominent: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if prominent {
                Button(action: action) {
                    serverControlButtonLabel(title: title, isLoading: isLoading)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) {
                    serverControlButtonLabel(title: title, isLoading: isLoading)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .frame(minWidth: 76)
        .disabled(disabled)
    }

    private func serverControlButtonLabel(title: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
        }
    }

    private var serverCardTone: SettingsCardTone {
        switch llmService.serverState {
        case .running:
            return .accent(.green)
        case .starting:
            return .accent(.blue)
        case .stopped:
            return .neutral
        case .failed:
            return .accent(.orange)
        }
    }

    private func cardBackground(for tone: SettingsCardTone) -> some ShapeStyle {
        switch tone {
        case .neutral:
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .accent(let color):
            return AnyShapeStyle(
                LinearGradient(
                    colors: [color.opacity(0.10), color.opacity(0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private func cardBorder(for tone: SettingsCardTone) -> Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.06)
        case .accent(let color):
            return color.opacity(0.18)
        }
    }
}

private enum SettingsCardTone {
    case neutral
    case accent(Color)
}
