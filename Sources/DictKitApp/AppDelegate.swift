import AppKit
import SwiftUI
import AnkiMateLLM

/// Handles app termination: shows a sync progress window if there are pending changes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var syncScheduler: SyncScheduler?
    var syncStatus: SyncStatus?
    var llmService: LLMService?
    private var syncWindow: NSWindow?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let shouldPauseDownloads = llmService?.downloadManager.hasActiveDownloads == true
        guard let scheduler = syncScheduler,
              let status = syncStatus,
              WebDAVCredentials.hasBeenConfigured,
              status.hasPendingChanges || shouldPauseDownloads
        else {
            if shouldPauseDownloads {
                Task { @MainActor in
                    await self.llmService?.downloadManager.pauseAllActiveDownloads()
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            }
            return .terminateNow
        }

        if status.hasPendingChanges {
            showSyncProgressWindow(status: status)
        }

        // Run sync, then terminate
        Task { @MainActor in
            if shouldPauseDownloads {
                await self.llmService?.downloadManager.pauseAllActiveDownloads()
            }
            if status.hasPendingChanges {
                await scheduler.syncNow()
            }
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
