import XCTest
@testable import DictKitApp
@testable import AnkiMateLLM

@MainActor
final class LLMServerControlsModelTests: XCTestCase {
    func testPerformStopTracksStopLoadingUntilStopCompletes() async {
        let service = TestLLMServerController()
        let sut = LLMServerControlsModel()

        let task = Task {
            await sut.performStop(using: service)
        }

        await waitUntil { service.stopStarted }
        XCTAssertTrue(sut.isStopping)
        XCTAssertFalse(sut.isRestarting)
        XCTAssertTrue(sut.isBusy)
        XCTAssertEqual(service.events, ["stop"])

        service.finishStop()
        _ = await task.result

        XCTAssertFalse(sut.isBusy)
        XCTAssertFalse(sut.isStopping)
    }

    func testPerformRestartStopsThenEnsuresReadyAndTracksRestartLoading() async throws {
        let service = TestLLMServerController()
        let sut = LLMServerControlsModel()

        let task = Task {
            try await sut.performRestart(using: service)
        }

        await waitUntil { service.stopStarted }
        XCTAssertTrue(sut.isRestarting)
        XCTAssertFalse(sut.isStopping)
        XCTAssertEqual(service.events, ["stop"])

        service.finishStop()
        await waitUntil { service.ensureReadyStarted }
        XCTAssertEqual(service.events, ["stop", "ensureReady"])
        XCTAssertTrue(sut.isRestarting)

        service.finishEnsureReady()
        _ = try await task.result.get()

        XCTAssertFalse(sut.isBusy)
        XCTAssertFalse(sut.isRestarting)
    }

    func testPerformRestartClearsLoadingWhenEnsureReadyFails() async {
        let service = TestLLMServerController(ensureReadyError: Failure.stub)
        let sut = LLMServerControlsModel()

        let task = Task {
            do {
                try await sut.performRestart(using: service)
                XCTFail("Expected error")
            } catch {
                XCTAssertTrue(error is Failure)
            }
        }

        await waitUntil { service.stopStarted }
        service.finishStop()
        await waitUntil { service.ensureReadyStarted }
        service.finishEnsureReady()
        _ = await task.result

        XCTAssertFalse(sut.isBusy)
        XCTAssertFalse(sut.isRestarting)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for condition")
                return
            }
            await Task.yield()
        }
    }
}

@MainActor
private final class TestLLMServerController: LLMServerControlling {
    private let ensureReadyError: Error?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var ensureReadyContinuation: CheckedContinuation<Void, Never>?

    private(set) var events: [String] = []
    var serverState: ServerProcessManager.State = .running(port: 61094)
    private(set) var stopStarted = false
    private(set) var ensureReadyStarted = false

    init(ensureReadyError: Error? = nil) {
        self.ensureReadyError = ensureReadyError
    }

    func startServer() async {
        events.append("start")
    }

    func stopServer() async {
        events.append("stop")
        stopStarted = true
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func ensureReady() async throws {
        events.append("ensureReady")
        ensureReadyStarted = true
        await withCheckedContinuation { continuation in
            ensureReadyContinuation = continuation
        }
        if let ensureReadyError {
            throw ensureReadyError
        }
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func finishEnsureReady() {
        ensureReadyContinuation?.resume()
        ensureReadyContinuation = nil
    }
}

private enum Failure: Error {
    case stub
}
