import AppKit
import SwiftUI
import AnkiMateLLM

/// Handles app termination: shows a sync progress window if there are pending changes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var syncScheduler: SyncScheduler?
    var syncStatus: SyncStatus?
    var llmService: LLMService?
    var terminationCoordinator = AppTerminationCoordinator()
    private var syncWindow: NSWindow?
    private var isPreparingForTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isPreparingForTermination {
            return .terminateLater
        }

        let plan = terminationCoordinator.makePlan(for: terminationSnapshot())
        guard plan.requiresAsyncPreparation else {
            return .terminateNow
        }

        isPreparingForTermination = true

        if plan.shouldSyncPendingChanges, let status = syncStatus {
            showSyncProgressWindow(status: status)
        }

        Task { @MainActor in
            await configuredTerminationCoordinator().prepareForTermination(using: plan)
            self.closeSyncProgressWindow()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    @MainActor
    private func showSyncProgressWindow(status: SyncStatus) {
        let view = QuitSyncProgressView()
            .environmentObject(status)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 100)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Syncing..."
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.makeKeyAndOrderFront(nil)
        syncWindow = window
    }

    private func closeSyncProgressWindow() {
        syncWindow?.close()
        syncWindow = nil
    }

    private func terminationSnapshot() -> AppTerminationSnapshot {
        AppTerminationSnapshot(
            hasActiveDownloads: llmService?.downloadManager.hasActiveDownloads == true,
            hasPendingSyncChanges: syncStatus?.hasPendingChanges == true,
            isSyncConfigured: syncScheduler != nil && WebDAVCredentials.hasBeenConfigured,
            isLLMServerActive: {
                guard let llmService else { return false }
                return llmService.serverState != .stopped
            }()
        )
    }

    private func configuredTerminationCoordinator() -> AppTerminationCoordinator {
        var coordinator = terminationCoordinator
        coordinator.pauseDownloads = { [weak llmService] in
            await llmService?.downloadManager.pauseAllActiveDownloads()
        }
        coordinator.syncNow = { [weak syncScheduler] in
            await syncScheduler?.syncNow()
        }
        coordinator.stopLLMServer = { [weak llmService] in
            await llmService?.stopServer()
        }
        return coordinator
    }
}

/// Minimal progress view shown during quit-time sync.
struct QuitSyncProgressView: View {
    @EnvironmentObject var syncStatus: SyncStatus

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.linear)

            Text(phaseText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 320)
    }

    private var phaseText: String {
        if case .syncing(let phase) = syncStatus.state {
            return phase
        }
        return "Syncing before quit..."
    }
}
