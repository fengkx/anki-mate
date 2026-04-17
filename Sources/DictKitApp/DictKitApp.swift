import SwiftUI

@main
struct DictKitApp: App {
    @StateObject private var viewModel = WordListViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
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
}
