import Foundation
import XCTest
@testable import AnkiMateLLM
import AnkiMateRPC

final class LLMDebugTraceWriterTests: XCTestCase {
    func testRequestResponseWritesStartAndFinishEventsToSingleJSONLFile() async throws {
        let fileURL = makeTemporaryFileURL()
        let writer = LLMDebugTraceWriter(fileURL: fileURL)
        let params = GenerateParams(
            prompt: "User prompt",
            systemPrompt: "System prompt",
            responseFormat: LLMResponseFormat(kind: .json),
            maxTokens: 512,
            temperature: 0.2
        )

        let sessionID = try await writer.beginRequest(
            transport: "request-response",
            rpcMethod: RPCMethod.generate,
            params: params,
            port: 8080
        )
        try await writer.finishRequest(
            sessionID,
            response: GenerateResult(
                text: "{\"ok\":true}",
                tokensUsed: 42,
                durationMs: 1234,
                finishReason: "stop"
            )
        )

        let events = try loadEvents(from: fileURL)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "request_started")
        XCTAssertEqual(events[0].params?.prompt, "User prompt")
        XCTAssertEqual(events[0].params?.systemPrompt, "System prompt")
        XCTAssertEqual(events[1].event, "request_finished")
        XCTAssertEqual(events[1].response?.text, "{\"ok\":true}")
        XCTAssertEqual(events[1].response?.tokensUsed, 42)
        XCTAssertEqual(events[1].response?.durationMs, 1234)
        XCTAssertEqual(events[0].id, events[1].id)
    }

    func testStreamWritesDeltaEventsThatCanBeTailed() async throws {
        let fileURL = makeTemporaryFileURL()
        let writer = LLMDebugTraceWriter(fileURL: fileURL)
        let params = GenerateParams(
            prompt: "Stream user prompt",
            systemPrompt: "Stream system prompt",
            maxTokens: 256,
            temperature: 0.7
        )

        let sessionID = try await writer.beginRequest(
            transport: "stream",
            rpcMethod: RPCMethod.generate,
            params: params,
            port: 9000
        )
        try await writer.appendStreamDelta("Hello", for: sessionID)
        try await writer.appendStreamDelta(", world", for: sessionID)
        try await writer.failRequest(
            sessionID,
            error: RPCClientError.decodingError("boom")
        )

        let events = try loadEvents(from: fileURL)
        XCTAssertEqual(events.map(\.event), [
            "request_started",
            "stream_delta",
            "stream_delta",
            "request_failed"
        ])
        XCTAssertEqual(events[1].delta, "Hello")
        XCTAssertEqual(events[2].delta, ", world")
        XCTAssertEqual(events[3].error?.type, "RPCClientError")
        XCTAssertEqual(events[3].error?.message, "Failed to decode response")
        XCTAssertEqual(events[3].error?.detail, "boom")
        XCTAssertEqual(Set(events.map(\.id)).count, 1)
    }

    private func loadEvents(from fileURL: URL) throws -> [LLMDebugTraceWriter.Event] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return try content
            .split(whereSeparator: \.isNewline)
            .map { line in
                try JSONDecoder().decode(
                    LLMDebugTraceWriter.Event.self,
                    from: Data(line.utf8)
                )
            }
    }

    private func makeTemporaryFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
