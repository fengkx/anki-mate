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
            // Try graceful shutdown via RPC
            do {
                let _: ShutdownResult = try await rpcClient.call(
                    method: RPCMethod.shutdown,
                    params: ShutdownParams(),
                    port: port
                )
                // Wait a moment for clean exit
                try? await Task.sleep(for: .seconds(1))
            } catch {
                // RPC failed, fall through to terminate
            }
        }

        if let proc = process, proc.isRunning {
            proc.terminate()
            // Give it a moment
            try? await Task.sleep(for: .milliseconds(500))
            if proc.isRunning {
                proc.interrupt()
            }
        }

        process = nil
        state = .stopped
    }

    // MARK: - Private

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
}
