import XCTest
@testable import AnkiMateServer
import AnkiMateRPC

final class RPCDispatcherTests: XCTestCase {
    func testGeneratePassesResponseFormatToEngine() throws {
        let engine = MockInferenceEngine()
        let dispatcher = RPCDispatcher(engine: engine)
        let responseFormat = LLMResponseFormat(
            kind: .jsonSchema,
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "value": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("value")]),
                "additionalProperties": .bool(false),
            ]),
            strict: true
        )
        let request = JSONRPCRawRequest(
            from: GenerateParams(
                prompt: "hello",
                systemPrompt: "system",
                responseFormat: responseFormat,
                maxTokens: 32,
                temperature: 0
            ),
            id: 7
        )

        _ = dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertEqual(engine.lastResponseFormat, responseFormat)
    }

    func testGenerateStreamingPassesResponseFormatToEngine() throws {
        let engine = MockInferenceEngine()
        let dispatcher = RPCDispatcher(engine: engine)
        let params = GenerateParams(
            prompt: "hello",
            responseFormat: .init(kind: .json),
            maxTokens: 16,
            temperature: 0.1
        )

        _ = try dispatcher.generateStreaming(params: params) { _ in }

        XCTAssertEqual(engine.lastResponseFormat, params.responseFormat)
    }

    func testGenerateReturnsModelNotLoadedErrorWhenEngineIsUnavailable() throws {
        let engine = MockInferenceEngine()
        engine.isModelLoaded = false
        let dispatcher = RPCDispatcher(engine: engine)
        let request = JSONRPCRawRequest(
            from: GenerateParams(prompt: "hello", maxTokens: 8, temperature: 0),
            id: 9
        )

        let response = dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertEqual(response.error?.code, -32001)
        XCTAssertEqual(response.error?.message, "No model loaded")
    }

    func testGenerateWrapsInferenceErrorsWithDiagnosticDetail() throws {
        let engine = MockInferenceEngine()
        engine.generateError = InferenceError.unsupportedResponseFormat("schema mismatch")
        let dispatcher = RPCDispatcher(engine: engine)
        let request = JSONRPCRawRequest(
            from: GenerateParams(prompt: "hello", maxTokens: 8, temperature: 0),
            id: 10
        )

        let response = dispatcher.dispatch(request, uptimeSeconds: 1)

        XCTAssertEqual(response.error?.code, -32003)
        XCTAssertEqual(response.error?.message, "Inference error")
        XCTAssertTrue(response.error?.data?.contains("unsupportedResponseFormat") ?? false)
        XCTAssertTrue(response.error?.data?.contains("schema mismatch") ?? false)
        XCTAssertTrue(response.error?.data?.contains("stack:") ?? false)
    }

    func testGenerateStreamingThrowsWhenModelIsNotLoaded() {
        let engine = MockInferenceEngine()
        engine.isModelLoaded = false
        let dispatcher = RPCDispatcher(engine: engine)
        let params = GenerateParams(prompt: "hello", maxTokens: 8, temperature: 0)

        XCTAssertThrowsError(try dispatcher.generateStreaming(params: params) { _ in }) { error in
            guard case InferenceError.modelNotLoaded = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGenerateStreamingPropagatesEngineErrors() {
        let engine = MockInferenceEngine()
        engine.streamingError = InferenceError.generationFailed("sampler rejected token")
        let dispatcher = RPCDispatcher(engine: engine)
        let params = GenerateParams(prompt: "hello", maxTokens: 8, temperature: 0.2)

        XCTAssertThrowsError(try dispatcher.generateStreaming(params: params) { _ in }) { error in
            guard case InferenceError.generationFailed(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "sampler rejected token")
        }
    }
}

private final class MockInferenceEngine: InferenceServing {
    var isModelLoaded: Bool = true
    var loadedModelPath: String?
    var lastResponseFormat: LLMResponseFormat?
    var generateError: Error?
    var streamingError: Error?

    func loadModel(path: String, contextSize: Int, gpuLayers: Int) throws {}
    func unloadModel() {}

    func generate(
        prompt: String,
        systemPrompt: String?,
        messages: [LLMMessage]?,
        tools: [LLMToolDefinition]?,
        toolChoice: String?,
        parallelToolCalls: Bool,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float
    ) throws -> GenerateResult {
        if let generateError {
            throw generateError
        }
        lastResponseFormat = responseFormat
        return GenerateResult(text: "{}", tokensUsed: 2, durationMs: 1, finishReason: "stop")
    }

    func generateStreaming(
        prompt: String,
        systemPrompt: String?,
        tools: [LLMToolDefinition]?,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float,
        onToken: (String) -> Void
    ) throws -> GenerateResult {
        if let streamingError {
            throw streamingError
        }
        lastResponseFormat = responseFormat
        onToken("{")
        onToken("}")
        return GenerateResult(text: "{}", tokensUsed: 2, durationMs: 1, finishReason: "stop")
    }
}

private extension JSONRPCRawRequest {
    init(from params: GenerateParams, id: Int) {
        let request = JSONRPCRequest(method: RPCMethod.generate, params: params, id: id)
        let data = try! JSONEncoder().encode(request)
        self = try! JSONDecoder().decode(JSONRPCRawRequest.self, from: data)
    }
}
