import SwiftUI
import AnkiMateLLM
import AnkiMateShared

@main
struct DictKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel: WordListViewModel
    @StateObject private var syncStatus: SyncStatus
    @StateObject private var llmService: LLMService
    @StateObject private var helpCenter: HelpCenterState
    @StateObject private var commandPalette: CommandPaletteViewModel
    @State private var syncScheduler: SyncScheduler?

    init() {
        AppStorageMigrator.migrateCurrentDeviceData()
        let wordListViewModel = WordListViewModel()
        _viewModel = StateObject(wrappedValue: wordListViewModel)
        _syncStatus = StateObject(wrappedValue: SyncStatus())
        _llmService = StateObject(wrappedValue: LLMService())
        _helpCenter = StateObject(wrappedValue: HelpCenterState())
        _commandPalette = StateObject(wrappedValue: CommandPaletteViewModel(wordListViewModel: wordListViewModel))
    }

    var body: some Scene {
        WindowGroup(AnkiMateIdentity.displayName) {
            ContentView(onSyncNow: syncNow, onIntervalChanged: { interval in
                syncScheduler?.updateInterval(interval)
            })
                .environmentObject(viewModel)
                .environmentObject(syncStatus)
                .environmentObject(llmService)
                .environmentObject(helpCenter)
                .environmentObject(commandPalette)
                .onAppear {
                    llmService.enableAutoStartOnAvailableModel()
                    setupSync()
                    helpCenter.presentGuideIfNeededOnFirstLaunch()
                }
        }
        .windowStyle(.hiddenTitleBar)
        Window("Help", id: AppWindowIDs.help) {
            HelpGuideView(showsCloseButton: false)
                .environmentObject(viewModel)
                .environmentObject(helpCenter)
        }
        Window("Sync", id: AppWindowIDs.syncSettings) {
            SyncSettingsView(onSyncNow: syncNow, onIntervalChanged: { interval in
                syncScheduler?.updateInterval(interval)
            })
            .environmentObject(syncStatus)
        }
        Window("AI", id: AppWindowIDs.aiSettings) {
            LLMSettingsView()
                .environmentObject(llmService)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("Export to Anki...") {
                    viewModel.showExportDialog = true
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!viewModel.canExportCurrentCollection)
                Button("Command Palette") {
                    commandPalette.togglePresentation()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            HelpCommands()
        }
    }

    private func setupSync() {
        guard syncScheduler == nil else { return }
        guard let store = viewModel.wordListStore else { return }

        let engine = SyncEngine(store: store, status: syncStatus) {
            viewModel.reloadFromStore()
        }
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
        appDelegate.llmService = llmService
    }

    private func syncNow() async {
        await syncScheduler?.syncNow()
    }
}

private struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Help") {
                openWindow(id: AppWindowIDs.help)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}
