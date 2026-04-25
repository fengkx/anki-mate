import Darwin
import XCTest
@testable import AnkiMateServer

final class LlamaServerChildRegistryTests: XCTestCase {
    func testRecordAndRemoveChild() {
        let registryURL = temporaryRegistryURL()
        let registry = LlamaServerChildRegistry(registryURL: registryURL)

        registry.recordChild(
            processID: 123,
            ownerProcessID: 456,
            executablePath: "/tmp/llama-server",
            port: 8081
        )

        XCTAssertEqual(registry.loadRecords().map(\.childProcessID), [123])

        registry.removeChild(processID: 123)

        XCTAssertEqual(registry.loadRecords(), [])
    }

    func testReapStaleChildrenTerminatesChildWhenOwnerExited() {
        let registryURL = temporaryRegistryURL()
        var liveProcesses: Set<Int32> = [100]
        var signals: [(Int32, Int32)] = []
        let registry = makeRegistry(
            registryURL: registryURL,
            liveProcesses: { liveProcesses },
            executablePaths: [100: "/tmp/llama-server"],
            signalProcess: { processID, signal in
                signals.append((processID, signal))
                if signal == SIGTERM {
                    liveProcesses.remove(processID)
                }
                return 0
            }
        )
        registry.recordChild(
            processID: 100,
            ownerProcessID: 200,
            executablePath: "/tmp/llama-server",
            port: 8081
        )

        registry.reapStaleChildren(currentOwnerProcessID: 999)

        XCTAssertEqual(signals.map(\.0), [100])
        XCTAssertEqual(signals.map(\.1), [SIGTERM])
        XCTAssertEqual(registry.loadRecords(), [])
    }

    func testReapStaleChildrenKeepsChildWhenOwnerIsAlive() {
        let registryURL = temporaryRegistryURL()
        let registry = makeRegistry(
            registryURL: registryURL,
            liveProcesses: { [100, 200] },
            executablePaths: [100: "/tmp/llama-server"]
        )
        registry.recordChild(
            processID: 100,
            ownerProcessID: 200,
            executablePath: "/tmp/llama-server",
            port: 8081
        )

        registry.reapStaleChildren(currentOwnerProcessID: 999)

        XCTAssertEqual(registry.loadRecords().map(\.childProcessID), [100])
    }

    func testReapStaleChildrenDoesNotKillReusedPIDWithDifferentExecutable() {
        let registryURL = temporaryRegistryURL()
        var signals: [(Int32, Int32)] = []
        let registry = makeRegistry(
            registryURL: registryURL,
            liveProcesses: { [100] },
            executablePaths: [100: "/usr/bin/other-process"],
            signalProcess: { processID, signal in
                signals.append((processID, signal))
                return 0
            }
        )
        registry.recordChild(
            processID: 100,
            ownerProcessID: 200,
            executablePath: "/tmp/llama-server",
            port: 8081
        )

        registry.reapStaleChildren(currentOwnerProcessID: 999)

        XCTAssertEqual(signals.count, 0)
        XCTAssertEqual(registry.loadRecords().map(\.childProcessID), [100])
    }

    private func makeRegistry(
        registryURL: URL,
        liveProcesses: @escaping () -> Set<Int32>,
        executablePaths: [Int32: String],
        signalProcess: @escaping LlamaServerChildRegistry.SignalProcess = { _, _ in 0 }
    ) -> LlamaServerChildRegistry {
        LlamaServerChildRegistry(
            registryURL: registryURL,
            processExists: { liveProcesses().contains($0) },
            executablePath: { executablePaths[$0] },
            signalProcess: signalProcess
        )
    }

    private func temporaryRegistryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("llama-server-children.json")
    }
}
