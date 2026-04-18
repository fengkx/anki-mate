// Server process manager — launches, monitors, and shuts down the inference server subprocess.

import Foundation
import AnkiMateRPC

@MainActor
public final class ServerProcessManager: ObservableObject {

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        public var port: Int? {
            if case .running(let p) = self { return p }
            return nil
        }
    }

    @Published public private(set) var state: State = .stopped

    private var process: Process?
    private var healthCheckTimer: Timer?
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3
    private let rpcClient: RPCClient

    public init(rpcClient: RPCClient) {
        self.rpcClient = rpcClient
    }

    deinit {
        healthCheckTimer?.invalidate()
    }

    // MARK: - Start

    public func start() async {
        guard state == .stopped || (state != .starting && !state.isRunning) else { return }

        state = .starting

        guard let serverPath = locateServerBinary() else {
            state = .failed("Server binary not found")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: serverPath)
        proc.arguments = ["0"] // auto-assign port
        proc.environment = Self.launchEnvironment(
            forServerBinaryAt: URL(fileURLWithPath: serverPath),
            baseEnvironment: ProcessInfo.processInfo.environment
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Forward server stderr to our stderr for debugging
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                FileHandle.standardError.write(data)
            }
        }

        do {
            try proc.run()
        } catch {
            state = .failed("Failed to launch server: \(error.localizedDescription)")
            return
        }

        self.process = proc

        // Read the LISTENING:<port> line from stdout
        let port = await readPortFromStdout(pipe: stdoutPipe)

        if let port = port {
            state = .running(port: port)
            consecutiveFailures = 0
            startHealthCheck(port: port)
        } else {
            state = .failed("Server did not report listening port")
            proc.terminate()
            self.process = nil
        }
    }

    // MARK: - Stop

    public func stop() async {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        if let port = state.port {
            do {
                let _: UnloadModelResult = try await rpcClient.call(
                    method: RPCMethod.unloadModel,
                    params: UnloadModelParams(),
                    port: port
                )
            } catch {
                // Best effort only. The server may already be unloading or have no model loaded.
            }

            // Try graceful shutdown via RPC
            do {
                let _: ShutdownResult = try await rpcClient.call(
                    method: RPCMethod.shutdown,
                    params: ShutdownParams(),
                    port: port
                )
            } catch {
                // RPC failed, fall through to terminate
            }
        }

        if let proc = process, proc.isRunning {
            let exitedGracefully = await Self.waitForExit(of: proc, timeout: .seconds(15))

            if !exitedGracefully, proc.isRunning {
                proc.terminate()
            }

            let exitedAfterTerminate: Bool
            if exitedGracefully {
                exitedAfterTerminate = true
            } else {
                exitedAfterTerminate = await Self.waitForExit(
                    of: proc,
                    timeout: .seconds(2)
                )
            }

            if !exitedAfterTerminate, proc.isRunning {
                proc.interrupt()
                _ = await Self.waitForExit(of: proc, timeout: .seconds(1))
            }
        }

        process = nil
        state = .stopped
    }

    // MARK: - Private

    static func launchEnvironment(
        forServerBinaryAt serverBinaryURL: URL,
        baseEnvironment: [String: String]
    ) -> [String: String] {
        var environment = baseEnvironment

        guard let runtimeLibraryDirectory = locateRuntimeLibraryDirectory(forServerBinaryAt: serverBinaryURL) else {
            return environment
        }

        let runtimeLibraryPath = runtimeLibraryDirectory.path
        environment["DYLD_LIBRARY_PATH"] = prependSearchPath(
            runtimeLibraryPath,
            to: environment["DYLD_LIBRARY_PATH"]
        )
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = prependSearchPath(
            runtimeLibraryPath,
            to: environment["DYLD_FALLBACK_LIBRARY_PATH"]
        )

        return environment
    }

    private func locateServerBinary() -> String? {
        // In app bundle
        if let bundlePath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("anki-mate-server").path,
           FileManager.default.isExecutableFile(atPath: bundlePath) {
            return bundlePath
        }

        // Development: look in .build/debug/
        let devPaths = [
            ".build/debug/AnkiMateServer",
            ".build/release/AnkiMateServer",
        ]
        for path in devPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func locateRuntimeLibraryDirectory(forServerBinaryAt serverBinaryURL: URL) -> URL? {
        let fileManager = FileManager.default
        let frameworksDirectory = serverBinaryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks", isDirectory: true)

        if fileManager.fileExists(atPath: frameworksDirectory.appendingPathComponent("libllama.0.dylib").path) {
            return frameworksDirectory
        }

        let searchRoots = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
            serverBinaryURL.deletingLastPathComponent(),
            serverBinaryURL.deletingLastPathComponent().deletingLastPathComponent(),
            serverBinaryURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
        ]

        for root in searchRoots {
            let candidate = root
                .appendingPathComponent("vendor", isDirectory: true)
                .appendingPathComponent("llama-install", isDirectory: true)
                .appendingPathComponent("lib", isDirectory: true)

            if fileManager.fileExists(atPath: candidate.appendingPathComponent("libllama.0.dylib").path) {
                return candidate
            }
        }

        return nil
    }

    private static func prependSearchPath(_ value: String, to existing: String?) -> String {
        let separator = ":"
        let currentValues = (existing ?? "")
            .split(separator: Character(separator))
            .map(String.init)
            .filter { !$0.isEmpty }

        if currentValues.contains(value) {
            return ([value] + currentValues.filter { $0 != value }).joined(separator: separator)
        }

        return ([value] + currentValues).joined(separator: separator)
    }

    private func readPortFromStdout(pipe: Pipe) async -> Int? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                var accumulated = Data()
                let timeout = Date().addingTimeInterval(10)

                while Date() < timeout {
                    let data = handle.availableData
                    if data.isEmpty {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    accumulated.append(data)

                    if let str = String(data: accumulated, encoding: .utf8),
                       str.contains("\n") {
                        // Parse LISTENING:<port>
                        for line in str.split(separator: "\n") {
                            if line.hasPrefix("LISTENING:"),
                               let port = Int(line.dropFirst("LISTENING:".count)) {
                                continuation.resume(returning: port)
                                return
                            }
                        }
                    }
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func startHealthCheck(port: Int) {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performHealthCheck(port: port)
            }
        }
    }

    private func performHealthCheck(port: Int) async {
        do {
            let _: HealthResult = try await rpcClient.call(
                method: RPCMethod.health,
                params: HealthParams(),
                port: port
            )
            consecutiveFailures = 0
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures {
                state = .failed("Server health check failed \(consecutiveFailures) times")
                await stop()
            }
        }
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
