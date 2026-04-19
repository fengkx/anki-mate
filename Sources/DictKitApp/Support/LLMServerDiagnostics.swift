import AppKit
import AnkiMateLLM

enum LLMServerDiagnostics {
    @MainActor
    static func copyDiagnostics(service: LLMService) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(makeReport(service: service), forType: .string)
    }

    @MainActor
    static func makeReport(service: LLMService) -> String {
        [
            "Anki Mate Local AI Diagnostics",
            "App version: \(appVersionString())",
            "Server state: \(describe(service.serverState))",
            "Selected model: \(service.selectedModelId.isEmpty ? "none" : service.selectedModelId)",
            "Has downloaded selected model: \(service.hasModel ? "yes" : "no")",
            "Downloaded model count: \(downloadedModelCount(service))",
            "Bundle server binary: \(describe(path: bundleServerBinaryPath()))",
            "Development server binary: \(describe(path: developmentServerBinaryPath()))",
            "Release server binary: \(describe(path: releaseServerBinaryPath()))",
            "Working directory: \(FileManager.default.currentDirectoryPath)",
        ]
        .joined(separator: "\n")
    }

    private static func describe(_ state: ServerProcessManager.State) -> String {
        switch state {
        case .stopped:
            return "stopped"
        case .starting:
            return "starting"
        case .running(let port):
            return "running (port \(port))"
        case .failed(let message):
            return "failed (\(message))"
        }
    }

    @MainActor
    private static func downloadedModelCount(_ service: LLMService) -> Int {
        service.registry.models.filter { service.downloadManager.isDownloaded($0) }.count
    }

    private static func appVersionString() -> String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        switch (shortVersion, buildNumber) {
        case let (.some(shortVersion), .some(buildNumber)):
            return "\(shortVersion) (\(buildNumber))"
        case let (.some(shortVersion), .none):
            return shortVersion
        case let (.none, .some(buildNumber)):
            return buildNumber
        case (.none, .none):
            return "unknown"
        }
    }

    private static func bundleServerBinaryPath() -> String? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("anki-mate-server")
            .path
    }

    private static func developmentServerBinaryPath() -> String {
        ".build/debug/AnkiMateServer"
    }

    private static func releaseServerBinaryPath() -> String {
        ".build/release/AnkiMateServer"
    }

    private static func describe(path: String?) -> String {
        guard let path else { return "not available" }

        let exists = FileManager.default.isExecutableFile(atPath: path)
        return "\(path) [\(exists ? "found" : "missing")]"
    }
}
