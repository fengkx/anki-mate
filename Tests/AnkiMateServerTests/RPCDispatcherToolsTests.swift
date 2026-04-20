import XCTest
@testable import AnkiMateServer
import AnkiMateRPC

/// Tests that `RPCDispatcher` correctly threads the OpenAI-style tool-call
/// parameters from `GenerateParams` into the single `InferenceServing.generate`
/// method, and that the `toolCalls` field on the response survives JSON
/// round-tripping.
final class RPCDispatcherToolsTests: XCTestCase {
    func testGenerateForwardsToolCallParametersToEngine() throws {
        let engine = ToolsMockInferenceEngine()
        engine.nextResult = GenerateResult(
            text: "done",
            tokensUsed: 4,
            durationMs: 7,
            finishReason: "stop",
            toolCalls: [
                LLMToolCall(id: "call-1", name: "propose_example", arguments: .object(["text": .string("hi")]))
            ]
        )
        let dispatcher = RPCDispatcher(engine: engine)
        let tools = [
            LLMToolDefinition(
                name: "propose_example",
                description: "Propose an example sentence",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "text": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("text")])
                ])
            )
        ]
        let params = GenerateParams(
            prompt: "hello",
            systemPrompt: "you are helpful",
            messages: [
                LLMMessage(role: .user, content: "propose an example for `apple`")
            ],
            tools: tools,
            toolChoice: "auto",
            parallelToolCalls: true,
            maxTokens: 128,
            temperature: 0.2
        )
        let request = JSONRPCRawRequest(from: params, id: 11)

        let response = dispatcher.dispatch(request, uptimeSeconds: 1)
        XCTAssertNil(response.error)
        XCTAssertEqual(engine.generateCallCount, 1)
        XCTAssertEqual(engine.lastTools?.first?.name, "propose_example")
        XCTAssertEqual(engine.lastToolChoice, "auto")
        XCTAssertEqual(engine.lastParallelToolCalls, true)
        XCTAssertEqual(engine.lastMessages?.count, 1)

        // Round-trip the result envelope through JSON to confirm `toolCalls`
        // survives serialization.
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(RoundTripEnvelope.self, from: encoded)
        XCTAssertEqual(decoded.result?.text, "done")
        XCTAssertEqual(decoded.result?.toolCalls?.count, 1)
        XCTAssertEqual(decoded.result?.toolCalls?.first?.name, "propose_example")
        XCTAssertEqual(decoded.result?.toolCalls?.first?.id, "call-1")
    }

    func testGenerateOmitsToolsWhenNoneProvided() throws {
        let engine = ToolsMockInferenceEngine()
        engine.nextResult = GenerateResult(text: "legacy", tokensUsed: 0, durationMs: 0, finishReason: "stop")
        let dispatcher = RPCDispatcher(engine: engine)
        let params = GenerateParams(prompt: "hi", maxTokens: 16, temperature: 0)
        let request = JSONRPCRawRequest(from: params, id: 12)

        let response = dispatcher.dispatch(request, uptimeSeconds: 1)
        XCTAssertNil(response.error)
        XCTAssertEqual(engine.generateCallCount, 1)
        XCTAssertNil(engine.lastTools)
        XCTAssertNil(engine.lastToolChoice)
        XCTAssertEqual(engine.lastParallelToolCalls, false)
    }

    func testGenerateStreamingRefusesToolsRequest() {
        let engine = ToolsMockInferenceEngine()
        let dispatcher = RPCDispatcher(engine: engine)
        let params = GenerateParams(
            prompt: "hi",
            tools: [LLMToolDefinition(name: "propose_example")],
            maxTokens: 16,
            temperature: 0
        )

        XCTAssertThrowsError(try dispatcher.generateStreaming(params: params) { _ in }) { error in
            guard case InferenceError.unsupportedResponseFormat = error else {
                return XCTFail("expected unsupportedResponseFormat, got \(error)")
            }
        }
    }
}

// MARK: - Helpers

private struct RoundTripEnvelope: Decodable {
    let result: GenerateResult?
}

private final class ToolsMockInferenceEngine: InferenceServing {
    var isModelLoaded: Bool = true
    var loadedModelPath: String?
    var nextResult: GenerateResult?
    var lastTools: [LLMToolDefinition]?
    var lastMessages: [LLMMessage]?
    var lastToolChoice: String?
    var lastParallelToolCalls: Bool = false
    var generateCallCount = 0

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
        generateCallCount += 1
        lastTools = tools
        lastMessages = messages
        lastToolChoice = toolChoice
        lastParallelToolCalls = parallelToolCalls
        return nextResult ?? GenerateResult(text: "", tokensUsed: 0, durationMs: 0, finishReason: "stop")
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
        GenerateResult(text: "", tokensUsed: 0, durationMs: 0, finishReason: "stop")
    }
}

private extension JSONRPCRawRequest {
    init(from params: GenerateParams, id: Int) {
        let request = JSONRPCRequest(method: RPCMethod.generate, params: params, id: id)
        let data = try! JSONEncoder().encode(request)
        self = try! JSONDecoder().decode(JSONRPCRawRequest.self, from: data)
    }
}
