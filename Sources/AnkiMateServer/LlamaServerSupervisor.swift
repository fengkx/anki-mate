// LlamaServerSupervisor — manages a llama-server child process.
//
// Responsibilities:
// - Start/stop llama-server with a specific model
// - Health probe to confirm readiness
// - Crash detection via termination handler
// - Single-model restart strategy (no router mode)

import Darwin
import Foundation
import AnkiMateRPC

// MARK: - State

enum LlamaServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready(port: Int, modelPath: String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var port: Int? {
        if case .ready(let port, _) = self { return port }
        return nil
    }

    var modelPath: String? {
        if case .ready(_, let path) = self { return path }
        return nil
    }
}

// MARK: - Protocol

protocol LlamaServerSupervising: AnyObject {
    var state: LlamaServerState { get }
    var loadedModelPath: String? { get }
    var childPort: Int? { get }

    func loadModel(path: String, mmprojPath: String?, contextSize: Int, gpuLayers: Int) async throws
    func unloadModel() async
    func shutdown() async
}

// MARK: - Errors

enum SupervisorError: Error, LocalizedError {
    case binaryNotFound
    case launchFailed(String)
    case healthCheckTimeout
    case childCrashed(Int32)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "llama-server binary not found"
        case .launchFailed(let msg): return "Failed to launch llama-server: \(msg)"
        case .healthCheckTimeout: return "llama-server health check timed out"
        case .childCrashed(let code): return "llama-server exited with code \(code)"
        }
    }
}

// MARK: - Implementation

final class LlamaServerSupervisor: LlamaServerSupervising {
    private(set) var state: LlamaServerState = .stopped
    private var process: Process?
    private let internalPort: Int
    private let healthCheckTimeoutSeconds: TimeInterval
    private let childRegistry: LlamaServerChildRegistry

    var loadedModelPath: String? { state.modelPath }
    var childPort: Int? { state.port }

    init(
        childPort: Int,
        healthCheckTimeoutSeconds: TimeInterval = 120,
        childRegistry: LlamaServerChildRegistry = LlamaServerChildRegistry()
    ) {
        self.internalPort = childPort
        self.healthCheckTimeoutSeconds = healthCheckTimeoutSeconds
        self.childRegistry = childRegistry
    }

    // MARK: - Public

    func loadModel(path: String, mmprojPath: String?, contextSize: Int, gpuLayers: Int) async throws {
        // Idempotent: already ready with the same model
        if case .ready(_, let currentPath) = state, currentPath == path {
            return
        }

        // Kill existing child if running
        if case .ready = state {
            await stopChild()
        } else if case .starting = state {
            await stopChild()
        }

        state = .starting

        guard let binaryPath = locateLlamaServerBinary() else {
            state = .failed("llama-server binary not found")
            throw SupervisorError.binaryNotFound
        }
        let normalizedBinaryPath = Self.normalizedExecutablePath(binaryPath)

        childRegistry.reapStaleChildren()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: normalizedBinaryPath)
        proc.arguments = Self.launchArguments(
            port: internalPort,
            modelPath: path,
            mmprojPath: mmprojPath,
            contextSize: contextSize,
            gpuLayers: gpuLayers
        )
        proc.environment = Self.buildEnvironment(
            forBinaryAt: URL(fileURLWithPath: binaryPath),
            baseEnvironment: ProcessInfo.processInfo.environment
        )

        // Forward child stderr to our stderr
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                FileHandle.standardError.write(data)
            }
        }

        // Discard stdout
        proc.standardOutput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            state = .failed("Failed to launch: \(error.localizedDescription)")
            throw SupervisorError.launchFailed(error.localizedDescription)
        }

        self.process = proc
        childRegistry.recordChild(
            processID: proc.processIdentifier,
            ownerProcessID: ProcessInfo.processInfo.processIdentifier,
            executablePath: normalizedBinaryPath,
            port: internalPort
        )

        // Crash detection
        proc.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            let exitCode = terminatedProcess.terminationStatus
            self.childRegistry.removeChild(processID: terminatedProcess.processIdentifier)
            // Only mark as failed if we didn't stop it intentionally
            if case .ready = self.state {
                fputs("llama-server child exited unexpectedly with code \(exitCode)\n", stderr)
                self.state = .failed("child exited with code \(exitCode)")
            }
        }

        // Wait for health check
        do {
            try await waitForHealthy(port: internalPort)
        } catch {
            await stopChild()
            state = .failed("Health check failed: \(error.localizedDescription)")
            throw error
        }

        state = .ready(port: internalPort, modelPath: path)
        fputs("llama-server ready on port \(internalPort) with model: \(path)\n", stderr)
    }

    func unloadModel() async {
        await stopChild()
        state = .stopped
    }

    func shutdown() async {
        await stopChild()
        state = .stopped
    }

    // MARK: - Child Process Management

    private func stopChild() async {
        guard let proc = process else { return }
        let processID = proc.processIdentifier

        // Mark state before stopping so terminationHandler doesn't fire spuriously
        let previousState = state
        if case .ready = previousState {
            state = .stopped
        }

        // Try graceful shutdown via /quit endpoint
        if proc.isRunning {
            await sendQuitRequest(port: internalPort)
            let exited = await Self.waitForExit(of: proc, timeout: .seconds(5))

            if !exited, proc.isRunning {
                proc.terminate()
                let exitedAfterTerm = await Self.waitForExit(of: proc, timeout: .seconds(2))

                if !exitedAfterTerm, proc.isRunning {
                    proc.interrupt()
                    let exitedAfterInterrupt = await Self.waitForExit(of: proc, timeout: .seconds(1))

                    if !exitedAfterInterrupt, proc.isRunning {
                        Darwin.kill(processID, SIGKILL)
                        _ = await Self.waitForExit(of: proc, timeout: .seconds(1))
                    }
                }
            }
        }

        childRegistry.removeChild(processID: processID)
        process = nil
    }

    private func sendQuitRequest(port: Int) async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/quit")!)
        request.httpMethod = "POST"
        request.httpBody = "{}".data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Health Check

    private func waitForHealthy(port: Int) async throws {
        let deadline = Date().addingTimeInterval(healthCheckTimeoutSeconds)
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!

        while Date() < deadline {
            // Check if process died during startup
            if let proc = process, !proc.isRunning {
                throw SupervisorError.childCrashed(proc.terminationStatus)
            }

            do {
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = 2
                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let status = json["status"] as? String {
                        if status == "ok" || status == "no slot available" {
                            return
                        }
                    }
                }
            } catch {
                // Connection refused or timeout — server not ready yet
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        throw SupervisorError.healthCheckTimeout
    }

    // MARK: - Binary Location

    private func locateLlamaServerBinary() -> String? {
        let fileManager = FileManager.default

        // 1. App bundle
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("llama-server").path,
           fileManager.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }

        // 2. vendor/llama-install/bin/ from cwd
        let vendorPath = "vendor/llama-install/bin/llama-server"
        if fileManager.isExecutableFile(atPath: vendorPath) {
            return vendorPath
        }

        // 3. Walk up from binary location
        if let binaryURL = Bundle.main.executableURL {
            var searchDir = binaryURL.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = searchDir
                    .appendingPathComponent("vendor")
                    .appendingPathComponent("llama-install")
                    .appendingPathComponent("bin")
                    .appendingPathComponent("llama-server")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
                searchDir = searchDir.deletingLastPathComponent()
            }
        }

        return nil
    }

    static func launchArguments(
        port: Int,
        modelPath: String,
        mmprojPath: String? = nil,
        contextSize: Int,
        gpuLayers: Int
    ) -> [String] {
        var arguments = [
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--jinja",
            "--no-webui",
            "--reasoning", "auto",
            "--flash-attn", "on",
            "-m", modelPath,
            "-c", "\(contextSize)",
            "-ngl", "\(gpuLayers)",
        ]
        if let mmprojPath, !mmprojPath.isEmpty {
            arguments.append(contentsOf: ["--mmproj", mmprojPath])
        }
        return arguments
    }

    static func normalizedExecutablePath(_ path: String) -> String {
        LlamaServerChildRegistry.normalizedPath(path)
    }

    // MARK: - Environment

    static func buildEnvironment(
        forBinaryAt binaryURL: URL,
        baseEnvironment: [String: String]
    ) -> [String: String] {
        var environment = baseEnvironment

        guard let libDir = locateRuntimeLibraryDirectory(forBinaryAt: binaryURL) else {
            return environment
        }

        let libPath = libDir.path
        environment["DYLD_LIBRARY_PATH"] = prependPath(libPath, to: environment["DYLD_LIBRARY_PATH"])
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = prependPath(libPath, to: environment["DYLD_FALLBACK_LIBRARY_PATH"])

        return environment
    }

    private static func locateRuntimeLibraryDirectory(forBinaryAt binaryURL: URL) -> URL? {
        let fileManager = FileManager.default
        let marker = "libllama.0.dylib"

        // Check Frameworks dir (app bundle)
        let frameworksDir = binaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks", isDirectory: true)
        if fileManager.fileExists(atPath: frameworksDir.appendingPathComponent(marker).path) {
            return frameworksDir
        }

        // Search vendor/llama-install/lib from various roots
        let searchRoots = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
            binaryURL.deletingLastPathComponent(),
            binaryURL.deletingLastPathComponent().deletingLastPathComponent(),
            binaryURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
        ]

        for root in searchRoots {
            let candidate = root
                .appendingPathComponent("vendor", isDirectory: true)
                .appendingPathComponent("llama-install", isDirectory: true)
                .appendingPathComponent("lib", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(marker).path) {
                return candidate
            }
        }

        return nil
    }

    private static func prependPath(_ value: String, to existing: String?) -> String {
        let current = (existing ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }

        if current.contains(value) {
            return ([value] + current.filter { $0 != value }).joined(separator: ":")
        }
        return ([value] + current).joined(separator: ":")
    }

    private static func waitForExit(of process: Process, timeout: Duration) async -> Bool {
        let start = ContinuousClock.now
        let clock = ContinuousClock()

        while process.isRunning {
            if clock.now - start >= timeout {
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
