import AnkiMateLLM
import Combine
import Foundation

@MainActor
protocol LLMServerControlling: AnyObject {
    var serverState: ServerProcessManager.State { get }

    func startServer() async
    func stopServer() async
    func ensureReady() async throws
}

extension LLMService: LLMServerControlling {}

@MainActor
final class LLMServerControlsModel: ObservableObject {
    enum Operation {
        case start
        case stop
        case restart
    }

    @Published private(set) var operation: Operation?

    var isBusy: Bool {
        operation != nil
    }

    var isStarting: Bool {
        operation == .start
    }

    var isStopping: Bool {
        operation == .stop
    }

    var isRestarting: Bool {
        operation == .restart
    }

    func performStart(using service: LLMServerControlling) async {
        guard operation == nil else { return }
        operation = .start
        defer { operation = nil }
        await service.startServer()
    }

    func performStop(using service: LLMServerControlling) async {
        guard operation == nil else { return }
        operation = .stop
        defer { operation = nil }
        await service.stopServer()
    }

    func performRestart(using service: LLMServerControlling) async throws {
        guard operation == nil else { return }
        operation = .restart
        defer { operation = nil }
        await service.stopServer()
        try await service.ensureReady()
    }
}
