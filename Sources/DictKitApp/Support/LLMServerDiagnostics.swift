import AppKit
import AnkiMateLLM

enum LLMServerDiagnostics {
    struct ReportSnapshot {
        let appVersion: String
        let serverState: ServerProcessManager.State
        let selectedModelId: String
        let hasDownloadedSelectedModel: Bool
        let downloadedModelCount: Int
        let bundleServerBinaryDescription: String
        let developmentServerBinaryDescription: String
        let releaseServerBinaryDescription: String
        let workingDirectory: String
    }

    @MainActor
    static func copyDiagnostics(service: LLMService) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(makeReport(service: service), forType: .string)
    }

    @MainActor
    static func makeReport(service: LLMService) -> String {
        makeReport(snapshot: snapshot(for: service))
    }

    static func makeReport(snapshot: ReportSnapshot) -> String {
        [
            "Anki Mate Local AI Diagnostics",
            "App version: \(snapshot.appVersion)",
            "Server state: \(describe(snapshot.serverState))",
            "Selected model: \(snapshot.selectedModelId.isEmpty ? "none" : snapshot.selectedModelId)",
            "Has downloaded selected model: \(snapshot.hasDownloadedSelectedModel ? "yes" : "no")",
            "Downloaded model count: \(snapshot.downloadedModelCount)",
            "Bundle server binary: \(snapshot.bundleServerBinaryDescription)",
            "Development server binary: \(snapshot.developmentServerBinaryDescription)",
            "Release server binary: \(snapshot.releaseServerBinaryDescription)",
            "Working directory: \(snapshot.workingDirectory)",
        ]
        .joined(separator: "\n")
    }

    @MainActor
    private static func snapshot(for service: LLMService) -> ReportSnapshot {
        ReportSnapshot(
            appVersion: appVersionString(),
            serverState: service.serverState,
            selectedModelId: service.selectedModelId,
            hasDownloadedSelectedModel: service.hasModel,
            downloadedModelCount: downloadedModelCount(service),
            bundleServerBinaryDescription: describe(path: bundleServerBinaryPath()),
            developmentServerBinaryDescription: describe(path: developmentServerBinaryPath()),
            releaseServerBinaryDescription: describe(path: releaseServerBinaryPath()),
            workingDirectory: FileManager.default.currentDirectoryPath
        )
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
