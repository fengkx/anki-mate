// Model download manager — downloads GGUF model files with progress tracking.
// Supports background download (continues when settings sheet is closed),
// pause/resume via URLSession resume data, and HuggingFace mirror configuration.

import AnkiMateShared
import Foundation
import AnkiMateRPC

@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    private struct PersistedResumeState: Codable, Equatable {
        let modelId: String
        let bytesWritten: Int64
        let totalBytes: Int64
    }

    private enum DownloadAssetKind: String {
        case model
        case mmproj
    }

    public enum LocalAssetState: Equatable, Sendable {
        case missingModel
        case missingMMProj
        case ready
    }

    public struct DownloadProgress: Equatable, Sendable {
        public let modelId: String
        public var state: DownloadState
        public var bytesWritten: Int64
        public var totalBytes: Int64
        public var bytesPerSecond: Double?
        public var recoverySuggestion: String?

        public init(
            modelId: String,
            state: DownloadState,
            bytesWritten: Int64,
            totalBytes: Int64,
            bytesPerSecond: Double? = nil,
            recoverySuggestion: String? = nil
        ) {
            self.modelId = modelId
            self.state = state
            self.bytesWritten = bytesWritten
            self.totalBytes = totalBytes
            self.bytesPerSecond = bytesPerSecond
            self.recoverySuggestion = recoverySuggestion
        }

        public var fractionCompleted: Double {
            totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
        }

        public var formattedProgress: String {
            let written = ByteCountFormatter.string(fromByteCount: bytesWritten, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(written) / \(total)"
        }

        public var formattedSpeed: String? {
            guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
            let bytes = Int64(bytesPerSecond.rounded())
            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "\(formatted)/s"
        }

        public var estimatedTimeRemaining: TimeInterval? {
            guard let bytesPerSecond, bytesPerSecond > 0, totalBytes > bytesWritten else { return nil }
            return Double(totalBytes - bytesWritten) / bytesPerSecond
        }

        public var formattedTimeRemaining: String? {
            guard let estimatedTimeRemaining else { return nil }
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = estimatedTimeRemaining >= 3600 ? [.hour, .minute] : [.minute, .second]
            formatter.unitsStyle = .abbreviated
            formatter.maximumUnitCount = 2
            return formatter.string(from: max(1, estimatedTimeRemaining.rounded()))
        }

        public var transferStatusText: String {
            if let formattedSpeed {
                if let formattedTimeRemaining {
                    return "\(formattedSpeed) · \(formattedTimeRemaining) left"
                }
                return formattedSpeed
            }

            guard state == .downloading else { return formattedProgress }
            return bytesWritten > 0 ? "Calculating speed..." : "Connecting..."
        }
    }

    public struct ActiveDownloadSummary: Equatable, Sendable {
        public let modelName: String
        public let fraction: Double
        public let statusText: String
    }

    public struct DownloadNotice: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case success
            case error
        }

        public let id: UUID
        public let kind: Kind
        public let modelId: String
        public let title: String
        public let message: String

        public init(
            id: UUID = UUID(),
            kind: Kind,
            modelId: String,
            title: String,
            message: String
        ) {
            self.id = id
            self.kind = kind
            self.modelId = modelId
            self.title = title
            self.message = message
        }
    }

    public enum DownloadState: Equatable, Sendable {
        case downloading
        case paused         // user paused, resume data available
        case completed
        case failed(String)
    }

    @Published public var downloads: [String: DownloadProgress] = [:]
    @Published public private(set) var deletingModelIds: Set<String> = []
    @Published public private(set) var latestNotice: DownloadNotice?

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
    public var activeDownloadSummary: ActiveDownloadSummary? {
        guard let (_, progress) = downloads.first(where: { $0.value.state == .downloading }) else {
            return nil
        }
        let model = modelInfoByModelId[progress.modelId]
        let name = model?.displayName ?? progress.modelId
        return ActiveDownloadSummary(
            modelName: name,
            fraction: progress.fractionCompleted,
            statusText: progress.transferStatusText
        )
    }

    private struct TransferSample {
        let bytesWritten: Int64
        let timestamp: Date
    }

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var modelIdByTask: [Int: String] = [:]
    private var modelInfoByTask: [Int: ModelInfo] = [:]
    private var assetKindByTask: [Int: DownloadAssetKind] = [:]
    private var baseBytesByTask: [Int: Int64] = [:]
    private var modelInfoByModelId: [String: ModelInfo] = [:]
    private var resumeDataByModelId: [String: Data] = [:]
    private var lastSampleByModelId: [String: TransferSample] = [:]
    private var persistedResumeStates: [String: PersistedResumeState] = [:]
    private let baseDirectoryURL: URL

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        let q = OperationQueue()
        q.name = "AnkiMate.ModelDownload"
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: q)
    }()

    public init(baseDirectoryURL: URL? = nil) {
        self.baseDirectoryURL = baseDirectoryURL ?? Self.defaultBaseDirectory
        self.hfMirror = UserDefaults.standard.string(forKey: "ankimate.hfMirror") ?? ""
        super.init()
        restorePersistedResumeStates()
    }

    // MARK: - Paths

    public static var defaultBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(AnkiMateIdentity.applicationSupportDirectoryName, isDirectory: true)
    }

    public var modelsDirectory: URL {
        baseDirectoryURL.appendingPathComponent("models", isDirectory: true)
    }

    public func localPath(for model: ModelInfo) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    public func localMMProjPath(for model: ModelInfo) -> URL? {
        guard let fileName = model.mmprojFileName else { return nil }
        return modelsDirectory.appendingPathComponent(fileName)
    }

    public func isDownloaded(_ model: ModelInfo) -> Bool {
        localAssetState(for: model) == .ready
    }

    public func localAssetState(for model: ModelInfo) -> LocalAssetState {
        guard FileManager.default.fileExists(atPath: localPath(for: model).path) else {
            return .missingModel
        }
        guard model.requiresMMProj else { return .ready }
        guard let mmprojPath = localMMProjPath(for: model),
              FileManager.default.fileExists(atPath: mmprojPath.path) else {
            return .missingMMProj
        }
        return .ready
    }

    public func downloadActionTitle(for model: ModelInfo) -> String {
        localAssetState(for: model) == .missingMMProj ? "Download Projector" : "Download"
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
        if latestNotice?.modelId == model.id {
            latestNotice = nil
        }
        let assetKind = nextMissingAssetKind(for: model)
        guard let url = downloadURL(for: model, assetKind: assetKind) else {
            setDownloadProgress(
                DownloadProgress(
                    modelId: model.id,
                    state: .failed("Invalid URL"),
                    bytesWritten: 0,
                    totalBytes: model.totalSizeBytes
                )
            )
            return
        }

        try? FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true
        )

        modelInfoByModelId[model.id] = model

        let task: URLSessionDownloadTask
        let resumedBytes: Int64
        let baseBytes = downloadedBytesBeforeCurrentAsset(for: model, assetKind: assetKind)

        // Try to resume from saved data
        if let resumeData = resumeDataByModelId.removeValue(forKey: model.id) {
            task = session.downloadTask(withResumeData: resumeData)
            resumedBytes = downloads[model.id]?.bytesWritten ?? 0
            removePersistedResumeState(for: model.id)
        } else {
            task = session.downloadTask(with: url)
            resumedBytes = 0
            removePersistedResumeState(for: model.id)
        }

        activeTasks[model.id] = task
        modelIdByTask[task.taskIdentifier] = model.id
        modelInfoByTask[task.taskIdentifier] = model
        assetKindByTask[task.taskIdentifier] = assetKind
        baseBytesByTask[task.taskIdentifier] = baseBytes

        setDownloadProgress(
            DownloadProgress(
                modelId: model.id,
                state: .downloading,
                bytesWritten: max(resumedBytes, baseBytes),
                totalBytes: model.totalSizeBytes,
                bytesPerSecond: nil
            )
        )
        lastSampleByModelId[model.id] = TransferSample(
            bytesWritten: max(resumedBytes, baseBytes),
            timestamp: Date()
        )

        task.resume()
    }

    private func nextMissingAssetKind(for model: ModelInfo) -> DownloadAssetKind {
        if !FileManager.default.fileExists(atPath: localPath(for: model).path) {
            return .model
        }
        if model.requiresMMProj,
           let mmprojPath = localMMProjPath(for: model),
           !FileManager.default.fileExists(atPath: mmprojPath.path) {
            return .mmproj
        }
        return .model
    }

    private func downloadURL(for model: ModelInfo, assetKind: DownloadAssetKind) -> URL? {
        switch assetKind {
        case .model:
            return mirroredURL(for: model.url)
        case .mmproj:
            guard let url = model.mmprojURL else { return nil }
            return mirroredURL(for: url)
        }
    }

    private func downloadedBytesBeforeCurrentAsset(for model: ModelInfo, assetKind: DownloadAssetKind) -> Int64 {
        switch assetKind {
        case .model:
            return 0
        case .mmproj:
            return model.sizeBytes
        }
    }

    /// Pause a download — saves resume data for later continuation.
    public func pause(modelId: String) {
        pause(modelId: modelId, completion: nil)
    }

    public func pauseAllActiveDownloads() async {
        let modelIds = Array(activeTasks.keys)
        guard !modelIds.isEmpty else { return }

        await withCheckedContinuation { continuation in
            var remaining = modelIds.count
            for modelId in modelIds {
                pause(modelId: modelId) {
                    remaining -= 1
                    if remaining == 0 {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func pause(modelId: String, completion: (() -> Void)?) {
        guard let task = activeTasks.removeValue(forKey: modelId) else {
            completion?()
            return
        }

        task.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    completion?()
                    return
                }
                if let data = resumeData {
                    self.resumeDataByModelId[modelId] = data
                    self.updateDownloadProgress(for: modelId) { progress in
                        progress.state = .paused
                        progress.bytesPerSecond = nil
                        progress.recoverySuggestion = "Resume whenever you're ready."
                    }
                    if let progress = self.downloads[modelId] {
                        try? self.persistResumeState(for: modelId, resumeData: data, progress: progress)
                    }
                } else {
                    self.updateDownloadProgress(for: modelId) { progress in
                        progress.state = .failed("Couldn't save resumable download state.")
                        progress.bytesPerSecond = nil
                        progress.recoverySuggestion = "Retry the download from the beginning."
                    }
                    self.removePersistedResumeState(for: modelId)
                }
                self.lastSampleByModelId.removeValue(forKey: modelId)
                // Clean up task mappings
                self.modelIdByTask.removeValue(forKey: task.taskIdentifier)
                self.modelInfoByTask.removeValue(forKey: task.taskIdentifier)
                self.assetKindByTask.removeValue(forKey: task.taskIdentifier)
                self.baseBytesByTask.removeValue(forKey: task.taskIdentifier)
                completion?()
            }
        }
    }

    /// Cancel a download completely — discards resume data.
    public func cancel(modelId: String) {
        if let task = activeTasks.removeValue(forKey: modelId) {
            task.cancel()
            modelIdByTask.removeValue(forKey: task.taskIdentifier)
            modelInfoByTask.removeValue(forKey: task.taskIdentifier)
            assetKindByTask.removeValue(forKey: task.taskIdentifier)
            baseBytesByTask.removeValue(forKey: task.taskIdentifier)
        }
        resumeDataByModelId.removeValue(forKey: modelId)
        lastSampleByModelId.removeValue(forKey: modelId)
        removePersistedResumeState(for: modelId)
        if latestNotice?.modelId == modelId {
            latestNotice = nil
        }
        removeDownloadProgress(for: modelId)
    }

    /// Check if a paused download can be resumed.
    public func canResume(modelId: String) -> Bool {
        resumeDataByModelId[modelId] != nil
    }

    public func isDeleting(modelId: String) -> Bool {
        deletingModelIds.contains(modelId)
    }

    /// Delete a downloaded model.
    public func deleteModel(_ model: ModelInfo) async throws {
        guard !isDeleting(modelId: model.id) else { return }

        deletingModelIds.insert(model.id)
        defer { deletingModelIds.remove(model.id) }

        cancel(modelId: model.id)
        let path = localPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            try await Task.detached(priority: .utility) {
                try FileManager.default.removeItem(at: path)
            }.value
        }
        if let mmprojPath = localMMProjPath(for: model),
           FileManager.default.fileExists(atPath: mmprojPath.path) {
            try await Task.detached(priority: .utility) {
                try FileManager.default.removeItem(at: mmprojPath)
            }.value
        }
        if latestNotice?.modelId == model.id {
            latestNotice = nil
        }
    }

    private func setDownloadProgress(_ progress: DownloadProgress) {
        downloads[progress.modelId] = progress
    }

    private func updateDownloadProgress(for modelId: String, _ update: (inout DownloadProgress) -> Void) {
        guard var progress = downloads[modelId] else { return }
        update(&progress)
        downloads[modelId] = progress
    }

    private func removeDownloadProgress(for modelId: String) {
        downloads.removeValue(forKey: modelId)
    }

    private var resumeDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("download-resume", isDirectory: true)
    }

    private var resumeIndexURL: URL {
        resumeDirectoryURL.appendingPathComponent("resume-state.json", isDirectory: false)
    }

    private func resumeDataURL(for modelId: String) -> URL {
        resumeDirectoryURL.appendingPathComponent("\(modelId).resume", isDirectory: false)
    }

    private func restorePersistedResumeStates() {
        try? FileManager.default.createDirectory(
            at: resumeDirectoryURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        guard let data = try? Data(contentsOf: resumeIndexURL),
              let decoded = try? JSONDecoder().decode([PersistedResumeState].self, from: data) else {
            return
        }

        persistedResumeStates = Dictionary(uniqueKeysWithValues: decoded.map { ($0.modelId, $0) })

        for state in decoded {
            let resumeURL = resumeDataURL(for: state.modelId)
            guard let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty else {
                persistedResumeStates.removeValue(forKey: state.modelId)
                continue
            }
            resumeDataByModelId[state.modelId] = resumeData
            downloads[state.modelId] = DownloadProgress(
                modelId: state.modelId,
                state: .paused,
                bytesWritten: state.bytesWritten,
                totalBytes: state.totalBytes,
                bytesPerSecond: nil,
                recoverySuggestion: "Resume whenever you're ready."
            )
        }

        writePersistedResumeIndex()
    }

    func persistResumeState(for modelId: String, resumeData: Data, progress: DownloadProgress) throws {
        try FileManager.default.createDirectory(
            at: resumeDirectoryURL,
            withIntermediateDirectories: true
        )
        try resumeData.write(to: resumeDataURL(for: modelId), options: .atomic)
        persistedResumeStates[modelId] = PersistedResumeState(
            modelId: modelId,
            bytesWritten: progress.bytesWritten,
            totalBytes: progress.totalBytes
        )
        writePersistedResumeIndex()
    }

    private func removePersistedResumeState(for modelId: String) {
        persistedResumeStates.removeValue(forKey: modelId)
        try? FileManager.default.removeItem(at: resumeDataURL(for: modelId))
        writePersistedResumeIndex()
    }

    private func writePersistedResumeIndex() {
        let states = persistedResumeStates.values.sorted { $0.modelId < $1.modelId }
        if states.isEmpty {
            try? FileManager.default.removeItem(at: resumeIndexURL)
            return
        }
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? data.write(to: resumeIndexURL, options: .atomic)
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
            let baseBytes = self.baseBytesByTask[taskId] ?? 0

            let now = Date()
            let previousSample = self.lastSampleByModelId[modelId]
            self.updateDownloadProgress(for: modelId) { progress in
                progress.bytesWritten = baseBytes + totalBytesWritten
                if totalBytesExpectedToWrite > 0 {
                    progress.totalBytes = max(progress.totalBytes, baseBytes + totalBytesExpectedToWrite)
                }

                if let previousSample {
                    let elapsed = now.timeIntervalSince(previousSample.timestamp)
                    let deltaBytes = progress.bytesWritten - previousSample.bytesWritten
                    if elapsed >= 0.4, deltaBytes >= 0 {
                        let instantSpeed = Double(deltaBytes) / elapsed
                        if instantSpeed > 0 {
                            if let existing = progress.bytesPerSecond, existing > 0 {
                                progress.bytesPerSecond = (existing * 0.7) + (instantSpeed * 0.3)
                            } else {
                                progress.bytesPerSecond = instantSpeed
                            }
                        }
                    }
                }
            }

            let shouldRefreshSample: Bool
            if let previousSample {
                shouldRefreshSample = now.timeIntervalSince(previousSample.timestamp) >= 0.4
            } else {
                shouldRefreshSample = true
            }

            if shouldRefreshSample {
                let currentBytes = baseBytes + totalBytesWritten
                self.lastSampleByModelId[modelId] = TransferSample(
                    bytesWritten: currentBytes,
                    timestamp: now
                )
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
                  let model = self.modelInfoByTask[taskId],
                  let assetKind = self.assetKindByTask[taskId] else { return }

            let destination: URL
            switch assetKind {
            case .model:
                destination = self.localPath(for: model)
            case .mmproj:
                guard let mmprojPath = self.localMMProjPath(for: model) else { return }
                destination = mmprojPath
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempCopy, to: destination)

                if assetKind == .model,
                   model.requiresMMProj,
                   let mmprojPath = self.localMMProjPath(for: model),
                   !FileManager.default.fileExists(atPath: mmprojPath.path) {
                    self.cleanupCompletedTask(taskId: taskId, modelId: modelId)
                    self.download(model: model)
                    return
                }

                self.updateDownloadProgress(for: modelId) { progress in
                    progress.state = .completed
                    progress.bytesWritten = max(progress.bytesWritten, progress.totalBytes)
                    progress.bytesPerSecond = nil
                    progress.recoverySuggestion = nil
                }
                self.resumeDataByModelId.removeValue(forKey: modelId)
                self.removePersistedResumeState(for: modelId)
                self.latestNotice = DownloadNotice(
                    kind: .success,
                    modelId: modelId,
                    title: "\(model.displayName) is ready",
                    message: "Select it to start using AI features."
                )
            } catch {
                try? FileManager.default.removeItem(at: tempCopy)
                self.updateDownloadProgress(for: modelId) { progress in
                    progress.state = .failed(error.localizedDescription)
                    progress.bytesPerSecond = nil
                    progress.recoverySuggestion = "Retry the download. If it keeps failing, try a mirror."
                }
                self.latestNotice = DownloadNotice(
                    kind: .error,
                    modelId: modelId,
                    title: "Couldn't finish downloading \(model.displayName)",
                    message: "Retry the download. If it keeps failing, try a mirror."
                )
            }

            self.cleanupCompletedTask(taskId: taskId, modelId: modelId)
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
                if let progress = self.downloads[modelId] {
                    try? self.persistResumeState(for: modelId, resumeData: data, progress: progress)
                }
            }

            if (error as NSError).code == NSURLErrorCancelled {
                // If we already set .paused via pause(), don't overwrite
                if self.downloads[modelId]?.state != .paused {
                    // Cancelled without pause — user hit cancel
                    self.downloads.removeValue(forKey: modelId)
                    self.resumeDataByModelId.removeValue(forKey: modelId)
                    self.removePersistedResumeState(for: modelId)
                }
                self.lastSampleByModelId.removeValue(forKey: modelId)
            } else {
                let message: String
                let hasResume = resumeData != nil
                let recoverySuggestion: String
                switch (error as NSError).code {
                case NSURLErrorTimedOut:
                    message = "Connection timed out." + (hasResume ? "" : " Check your network or try a HuggingFace mirror.")
                    recoverySuggestion = hasResume
                        ? "Resume to continue from where it stopped. If timeouts keep happening, try a mirror."
                        : "Retry the download. If it keeps timing out, try a mirror."
                case NSURLErrorNotConnectedToInternet:
                    message = "No internet connection."
                    recoverySuggestion = hasResume
                        ? "Reconnect to the internet, then resume."
                        : "Reconnect to the internet, then retry."
                case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                    message = "Cannot reach server. Try setting a HuggingFace mirror."
                    recoverySuggestion = "Set a HuggingFace mirror, then retry the download."
                case NSURLErrorNetworkConnectionLost:
                    message = "Network connection lost."
                    recoverySuggestion = hasResume
                        ? "Resume to continue from the last checkpoint."
                        : "Retry the download when the connection is stable."
                default:
                    message = error.localizedDescription
                    recoverySuggestion = hasResume
                        ? "Resume to continue from where it stopped."
                        : "Retry the download."
                }
                self.updateDownloadProgress(for: modelId) { progress in
                    progress.state = .failed(message)
                    progress.bytesPerSecond = nil
                    progress.recoverySuggestion = recoverySuggestion
                }
                if !hasResume {
                    self.removePersistedResumeState(for: modelId)
                }
                let modelName = self.modelInfoByModelId[modelId]?.displayName ?? modelId
                self.latestNotice = DownloadNotice(
                    kind: .error,
                    modelId: modelId,
                    title: "Download interrupted for \(modelName)",
                    message: recoverySuggestion
                )
                self.lastSampleByModelId.removeValue(forKey: modelId)
            }

            self.activeTasks.removeValue(forKey: modelId)
            self.modelIdByTask.removeValue(forKey: taskId)
            self.modelInfoByTask.removeValue(forKey: taskId)
            self.assetKindByTask.removeValue(forKey: taskId)
            self.baseBytesByTask.removeValue(forKey: taskId)
        }
    }

    private func cleanupCompletedTask(taskId: Int, modelId: String) {
        activeTasks.removeValue(forKey: modelId)
        modelIdByTask.removeValue(forKey: taskId)
        modelInfoByTask.removeValue(forKey: taskId)
        assetKindByTask.removeValue(forKey: taskId)
        baseBytesByTask.removeValue(forKey: taskId)
        lastSampleByModelId.removeValue(forKey: modelId)
    }

    public func dismissLatestNotice() {
        latestNotice = nil
    }
}
