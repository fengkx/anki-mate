import XCTest
@testable import AnkiMateServer
import AnkiMateRPC

final class RPCDispatcherTests: XCTestCase {
    func testHealthReturnsReadyWhenSupervisorHasModel() async {
        let supervisor = MockSupervisor()
        supervisor.state = .ready(port: 9999, modelPath: "/models/test.gguf")
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(method: RPCMethod.health, id: 1)

        let response = await dispatcher.dispatch(request, uptimeSeconds: 42)

        XCTAssertNil(response.error)
        let data = try! JSONEncoder().encode(response)
        let decoded = try! JSONDecoder().decode(HealthEnvelope.self, from: data)
        XCTAssertEqual(decoded.result?.status, .ready)
        XCTAssertEqual(decoded.result?.modelId, "/models/test.gguf")
        XCTAssertEqual(decoded.result?.uptimeSeconds, 42)
    }

    func testHealthReturnsNoModelWhenSupervisorIsStopped() async {
        let supervisor = MockSupervisor()
        supervisor.state = .stopped
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(method: RPCMethod.health, id: 2)

        let response = await dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertNil(response.error)
        let data = try! JSONEncoder().encode(response)
        let decoded = try! JSONDecoder().decode(HealthEnvelope.self, from: data)
        XCTAssertEqual(decoded.result?.status, .noModel)
        XCTAssertNil(decoded.result?.modelId)
    }

    func testHealthReturnsLoadingModelWhenSupervisorIsStarting() async {
        let supervisor = MockSupervisor()
        supervisor.state = .starting
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(method: RPCMethod.health, id: 3)

        let response = await dispatcher.dispatch(request, uptimeSeconds: 1)

        let data = try! JSONEncoder().encode(response)
        let decoded = try! JSONDecoder().decode(HealthEnvelope.self, from: data)
        XCTAssertEqual(decoded.result?.status, .loadingModel)
    }

    func testLoadModelCallsSupervisor() async {
        let supervisor = MockSupervisor()
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(
            method: RPCMethod.loadModel,
            params: LoadModelParams(modelPath: "/test.gguf", contextSize: 2048, gpuLayers: 99),
            id: 4
        )

        let response = await dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertNil(response.error)
        XCTAssertEqual(supervisor.loadModelPath, "/test.gguf")
        XCTAssertEqual(supervisor.loadModelContextSize, 2048)
        XCTAssertEqual(supervisor.loadModelGpuLayers, 99)
    }

    func testUnloadModelCallsSupervisor() async {
        let supervisor = MockSupervisor()
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(method: RPCMethod.unloadModel, id: 5)

        let response = await dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertNil(response.error)
        XCTAssertTrue(supervisor.unloadModelCalled)
    }

    func testGenerateMethodIsNoLongerSupported() async {
        let supervisor = MockSupervisor()
        supervisor.state = .stopped
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(method: "generate", id: 6)

        let response = await dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertEqual(response.error?.code, -32601)
    }

    func testShutdownCallsSupervisor() async {
        let supervisor = MockSupervisor()
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(method: RPCMethod.shutdown, id: 7)

        let response = await dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertNil(response.error)
        XCTAssertTrue(supervisor.shutdownCalled)
    }

    func testUnknownMethodReturnsError() async {
        let supervisor = MockSupervisor()
        let dispatcher = RPCDispatcher(supervisor: supervisor)
        let request = makeRawRequest(method: "nonexistent", id: 8)

        let response = await dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertEqual(response.error?.code, -32601)
    }
}

// MARK: - Helpers

private struct HealthEnvelope: Decodable {
    let result: HealthResult?
}

private final class MockSupervisor: LlamaServerSupervising {
    var state: LlamaServerState = .stopped
    var loadedModelPath: String? { state.modelPath }
    var childPort: Int? { state.port }

    var loadModelPath: String?
    var loadModelContextSize: Int?
    var loadModelGpuLayers: Int?
    var unloadModelCalled = false
    var shutdownCalled = false

    func loadModel(path: String, contextSize: Int, gpuLayers: Int) async throws {
        loadModelPath = path
        loadModelContextSize = contextSize
        loadModelGpuLayers = gpuLayers
        state = .ready(port: 9999, modelPath: path)
    }

    func unloadModel() async {
        unloadModelCalled = true
        state = .stopped
    }

    func shutdown() async {
        shutdownCalled = true
        state = .stopped
    }
}

private func makeRawRequest(method: String, id: Int) -> JSONRPCRawRequest {
    let json = """
    {"jsonrpc":"2.0","method":"\(method)","id":\(id)}
    """
    return try! JSONDecoder().decode(JSONRPCRawRequest.self, from: Data(json.utf8))
}

private func makeRawRequest<P: Encodable>(method: String, params: P, id: Int) -> JSONRPCRawRequest {
    let request = JSONRPCRequest(method: method, params: params, id: id)
    let data = try! JSONEncoder().encode(request)
    return try! JSONDecoder().decode(JSONRPCRawRequest.self, from: data)
}
