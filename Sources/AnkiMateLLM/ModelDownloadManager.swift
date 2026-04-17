// Model download manager — downloads GGUF model files with progress tracking.
// Supports background download (continues when settings sheet is closed),
// pause/resume via URLSession resume data, and HuggingFace mirror configuration.

import Foundation
import AnkiMateRPC

@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {

    public struct DownloadProgress: Equatable, Sendable {
        public let modelId: String
        public var state: DownloadState
        public var bytesWritten: Int64
        public var totalBytes: Int64

        public var fractionCompleted: Double {
            totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
        }

        public var formattedProgress: String {
            let written = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(written) / \(total)"
        }
    }

    public enum DownloadState: Equatable, Sendable {
        case downloading
        case paused         // user paused, resume data available
        case completed
        case failed(String)
    }

    @Published public var downloads: [String: DownloadProgress] = [:]

    /// HuggingFace mirror domain. Empty string means use original huggingface.co.
    @Published public var hfMirror: String {
        didSet {
            let trimmed = hfMirror.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: "ankimate.hfMirror")
        }
    }

    /// Whether any download is actively in progress.
    public var hasActiveDownloads: Bool {
        downloads.values.contains { $0.state == .downloading }
    }

    /// Summary for sidebar display — returns the first active download's progress, or nil.
    public var activeDownloadSummary: (modelName: String, fraction: Double)? {
        guard let (_, progress) = downloads.first(where: { $0.value.state == .downloading }) else {
            return nil
        }
        let model = modelInfoByModelId[progress.modelId]
        let name = model?.displayName ?? progress.modelId
        return (name, progress.fractionCompleted)
    }

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var modelIdByTask: [Int: String] = [:]
    private var modelInfoByTask: [Int: ModelInfo] = [:]
    private var modelInfoByModelId: [String: ModelInfo] = [:]
    private var resumeDataByModelId: [String: Data] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        let q = OperationQueue()
        q.name = "AnkiMate.ModelDownload"
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: q)
    }()

    public override init() {
        self.hfMirror = UserDefaults.standard.string(forKey: "ankimate.hfMirror") ?? ""
        super.init()
    }

    // MARK: - Paths

    public static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DictKit/models", isDirectory: true)
    }

    public func localPath(for model: ModelInfo) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.fileName)
    }

    public func isDownloaded(_ model: ModelInfo) -> Bool {
        FileManager.default.fileExists(atPath: localPath(for: model).path)
    }

    // MARK: - Mirror

    public func mirroredURL(for originalURL: String) -> URL? {
        let mirror = hfMirror.trimmingCharacters(in: .whitespacesAndNewlines)
        if mirror.isEmpty {
            return URL(string: originalURL)
        }
        let mirrored = originalURL.replacingOccurrences(of: "huggingface.co", with: mirror)
        return URL(string: mirrored)
    }

    // MARK: - Download / Resume

    /// Start or resume downloading a model.
    public func download(model: ModelInfo) {
        guard activeTasks[model.id] == nil else { return }
        guard let url = mirroredURL(for: model.url) else {
            downloads[model.id] = DownloadProgress(
                modelId: model.id, state: .failed("Invalid URL"),
                bytesWritten: 0, totalBytes: model.sizeBytes
            )
            return
        }

        try? FileManager.default.createDirectory(
            at: Self.modelsDirectory, withIntermediateDirectories: true
        )

        modelInfoByModelId[model.id] = model

        let task: URLSessionDownloadTask
        let resumedBytes: Int64

        // Try to resume from saved data
        if let resumeData = resumeDataByModelId.removeValue(forKey: model.id) {
            task = session.downloadTask(withResumeData: resumeData)
            resumedBytes = downloads[model.id]?.bytesWritten ?? 0
        } else {
            task = session.downloadTask(with: url)
            resumedBytes = 0
        }

        activeTasks[model.id] = task
        modelIdByTask[task.taskIdentifier] = model.id
        modelInfoByTask[task.taskIdentifier] = model

        downloads[model.id] = DownloadProgress(
            modelId: model.id,
            state: .downloading,
            bytesWritten: resumedBytes,
            totalBytes: model.sizeBytes
        )

        task.resume()
    }

    /// Pause a download — saves resume data for later continuation.
    public func pause(modelId: String) {
        guard let task = activeTasks.removeValue(forKey: modelId) else { return }

        task.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let data = resumeData {
                    self.resumeDataByModelId[modelId] = data
                }
                self.downloads[modelId]?.state = .paused
                // Clean up task mappings
                self.modelIdByTask.removeValue(forKey: task.taskIdentifier)
                self.modelInfoByTask.removeValue(forKey: task.taskIdentifier)
            }
        }
    }

    /// Cancel a download completely — discards resume data.
    public func cancel(modelId: String) {
        if let task = activeTasks.removeValue(forKey: modelId) {
            task.cancel()
            modelIdByTask.removeValue(forKey: task.taskIdentifier)
            modelInfoByTask.removeValue(forKey: task.taskIdentifier)
        }
        resumeDataByModelId.removeValue(forKey: modelId)
        downloads.removeValue(forKey: modelId)
    }

    /// Check if a paused download can be resumed.
    public func canResume(modelId: String) -> Bool {
        resumeDataByModelId[modelId] != nil
    }

    /// Delete a downloaded model.
    public func deleteModel(_ model: ModelInfo) throws {
        let path = localPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self = self,
                  let modelId = self.modelIdByTask[taskId] else { return }
            self.downloads[modelId]?.bytesWritten = totalBytesWritten
            if totalBytesExpectedToWrite > 0 {
                self.downloads[modelId]?.totalBytes = totalBytesExpectedToWrite
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gguf")
        try? FileManager.default.copyItem(at: location, to: tempCopy)

        Task { @MainActor [weak self] in
            guard let self = self,
                  let modelId = self.modelIdByTask[taskId],
                  let model = self.modelInfoByTask[taskId] else { return }

            let destination = self.localPath(for: model)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempCopy, to: destination)
                self.downloads[modelId]?.state = .completed
                self.resumeDataByModelId.removeValue(forKey: modelId)
            } catch {
                try? FileManager.default.removeItem(at: tempCopy)
                self.downloads[modelId]?.state = .failed(error.localizedDescription)
            }

            self.activeTasks.removeValue(forKey: modelId)
            self.modelIdByTask.removeValue(forKey: taskId)
            self.modelInfoByTask.removeValue(forKey: taskId)
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        let taskId = task.taskIdentifier

        // Extract resume data from the error if available (network failure mid-download)
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        Task { @MainActor [weak self] in
            guard let self = self,
                  let modelId = self.modelIdByTask[taskId] else { return }

            // Save resume data for retry
            if let data = resumeData {
                self.resumeDataByModelId[modelId] = data
            }

            if (error as NSError).code == NSURLErrorCancelled {
                // If we already set .paused via pause(), don't overwrite
                if self.downloads[modelId]?.state != .paused {
                    // Cancelled without pause — user hit cancel
                    self.downloads.removeValue(forKey: modelId)
                    self.resumeDataByModelId.removeValue(forKey: modelId)
                }
            } else {
                let message: String
                let hasResume = resumeData != nil
                switch (error as NSError).code {
                case NSURLErrorTimedOut:
                    message = "Connection timed out." + (hasResume ? "" : " Check your network or try a HuggingFace mirror.")
                case NSURLErrorNotConnectedToInternet:
                    message = "No internet connection."
                case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                    message = "Cannot reach server. Try setting a HuggingFace mirror."
                case NSURLErrorNetworkConnectionLost:
                    message = "Network connection lost."
                default:
                    message = error.localizedDescription
                }
                self.downloads[modelId]?.state = .failed(message)
            }

            self.activeTasks.removeValue(forKey: modelId)
            self.modelIdByTask.removeValue(forKey: taskId)
            self.modelInfoByTask.removeValue(forKey: taskId)
        }
    }
}
