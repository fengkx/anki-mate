import Darwin
import Foundation

struct LlamaServerChildRecord: Codable, Equatable {
    var childProcessID: Int32
    var ownerProcessID: Int32
    var executablePath: String
    var port: Int
    var createdAt: Date
}

final class LlamaServerChildRegistry {
    typealias ProcessExists = (Int32) -> Bool
    typealias ExecutablePath = (Int32) -> String?
    typealias SignalProcess = (Int32, Int32) -> Int32

    private let registryURL: URL
    private let processExists: ProcessExists
    private let executablePath: ExecutablePath
    private let signalProcess: SignalProcess
    private let fileManager: FileManager

    init(
        registryURL: URL = LlamaServerChildRegistry.defaultRegistryURL(),
        processExists: @escaping ProcessExists = LlamaServerChildRegistry.processExists,
        executablePath: @escaping ExecutablePath = LlamaServerChildRegistry.executablePath,
        signalProcess: @escaping SignalProcess = Darwin.kill,
        fileManager: FileManager = .default
    ) {
        self.registryURL = registryURL
        self.processExists = processExists
        self.executablePath = executablePath
        self.signalProcess = signalProcess
        self.fileManager = fileManager
    }

    func recordChild(processID: Int32, ownerProcessID: Int32, executablePath: String, port: Int) {
        var records = loadRecords().filter { $0.childProcessID != processID }
        records.append(
            LlamaServerChildRecord(
                childProcessID: processID,
                ownerProcessID: ownerProcessID,
                executablePath: Self.normalizedPath(executablePath),
                port: port,
                createdAt: Date()
            )
        )
        saveRecords(records)
    }

    func removeChild(processID: Int32) {
        saveRecords(loadRecords().filter { $0.childProcessID != processID })
    }

    func reapStaleChildren(currentOwnerProcessID: Int32 = getpid()) {
        let records = loadRecords()
        var kept: [LlamaServerChildRecord] = []

        for record in records {
            guard processExists(record.childProcessID) else {
                continue
            }

            if record.ownerProcessID == currentOwnerProcessID || processExists(record.ownerProcessID) {
                kept.append(record)
                continue
            }

            guard executablePath(record.childProcessID) == record.executablePath else {
                kept.append(record)
                continue
            }

            terminateStaleChild(processID: record.childProcessID)
            if processExists(record.childProcessID) {
                kept.append(record)
            }
        }

        saveRecords(kept)
    }

    func loadRecords() -> [LlamaServerChildRecord] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        return (try? JSONDecoder().decode([LlamaServerChildRecord].self, from: data)) ?? []
    }

    private func terminateStaleChild(processID: Int32) {
        _ = signalProcess(processID, SIGTERM)
        usleep(250_000)

        if processExists(processID) {
            _ = signalProcess(processID, SIGKILL)
            usleep(100_000)
        }
    }

    private func saveRecords(_ records: [LlamaServerChildRecord]) {
        do {
            try fileManager.createDirectory(
                at: registryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            fputs("warning: failed to update llama-server child registry: \(error.localizedDescription)\n", stderr)
        }
    }

    static func processExists(processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    static func executablePath(processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return normalizedPath(String(cString: buffer))
    }

    static func defaultRegistryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupport
            .appendingPathComponent("Anki Mate", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("llama-server-children.json")
    }

    static func normalizedPath(_ path: String) -> String {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(path)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
