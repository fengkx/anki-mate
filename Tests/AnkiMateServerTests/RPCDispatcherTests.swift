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
}

private final class MockInferenceEngine: InferenceServing {
    var isModelLoaded: Bool = true
    var loadedModelPath: String?
    var lastResponseFormat: LLMResponseFormat?

    func loadModel(path: String, contextSize: Int, gpuLayers: Int) throws {}
    func unloadModel() {}

    func generate(
        prompt: String,
        systemPrompt: String?,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float
    ) throws -> GenerateResult {
        lastResponseFormat = responseFormat
        return GenerateResult(text: "{}", tokensUsed: 2, durationMs: 1, finishReason: "stop")
    }

    func generateStreaming(
        prompt: String,
        systemPrompt: String?,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float,
        onToken: (String) -> Void
    ) throws -> GenerateResult {
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
