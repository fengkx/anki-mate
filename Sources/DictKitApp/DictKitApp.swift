import SwiftUI
import AnkiMateLLM

@main
struct DictKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = WordListViewModel()
    @StateObject private var syncStatus = SyncStatus()
    @StateObject private var llmService = LLMService()
    @State private var syncScheduler: SyncScheduler?

    var body: some Scene {
        WindowGroup {
            ContentView(onSyncNow: syncNow, onIntervalChanged: { interval in
                syncScheduler?.updateInterval(interval)
            })
                .environmentObject(viewModel)
                .environmentObject(syncStatus)
                .environmentObject(llmService)
                .onAppear {
                    setupSync()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("Export to Anki...") {
                    viewModel.showExportDialog = true
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!viewModel.canExportCurrentCollection)
            }
        }
    }

    private func setupSync() {
        guard syncScheduler == nil else { return }
        guard let store = viewModel.wordListStore else { return }

        let engine = SyncEngine(store: store, status: syncStatus)
        let scheduler = SyncScheduler(engine: engine, status: syncStatus)

        let isConfigured = WebDAVCredentials.hasBeenConfigured
        syncStatus.isConfigured = isConfigured

        // Check pending changes on startup
        engine.refreshPendingStatus()

        // Notify sync status when ViewModel mutates data
        viewModel.onDataChanged = { [weak syncStatus] in
            syncStatus?.hasPendingChanges = true
        }

        scheduler.start()
        syncScheduler = scheduler

        // Wire up AppDelegate for quit-time sync
        appDelegate.syncScheduler = scheduler
        appDelegate.syncStatus = syncStatus
    }

    private func syncNow() async {
        await syncScheduler?.syncNow()
    }
}
