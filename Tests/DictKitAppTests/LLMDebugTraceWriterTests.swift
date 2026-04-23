import Foundation
import XCTest
@testable import AnkiMateLLM
import AnkiMateRPC

final class LLMDebugTraceWriterTests: XCTestCase {
    func testRequestResponseWritesStartAndFinishEventsToSingleJSONLFile() async throws {
        let fileURL = makeTemporaryFileURL()
        let writer = LLMDebugTraceWriter(fileURL: fileURL)
        let request = ChatCompletionRequest(
            model: "/test.gguf",
            messages: [
                ChatMessage(role: "system", content: "System prompt"),
                ChatMessage(role: "user", content: "User prompt"),
            ],
            temperature: 0.2,
            max_completion_tokens: 512,
            response_format: ChatResponseFormat(type: "json_object")
        )

        let sessionID = try await writer.beginChatRequest(
            transport: "request-response",
            request: request,
            port: 8080
        )
        let response = ChatCompletionResponse(
            choices: [
                ChatCompletionResponse.Choice(
                    message: ChatMessage(role: "assistant", content: "{\"ok\":true}"),
                    finish_reason: "stop"
                )
            ],
            usage: ChatCompletionResponse.Usage(completion_tokens: 42)
        )
        try await writer.finishChatRequest(sessionID, response: response)

        let events = try loadEvents(from: fileURL)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "request_started")
        XCTAssertEqual(events[0].request?.model, "/test.gguf")
        XCTAssertEqual(events[1].event, "request_finished")
        XCTAssertEqual(events[1].response?.choices.first?.message.content?.plainText, "{\"ok\":true}")
        XCTAssertEqual(events[1].response?.usage?.completion_tokens, 42)
        XCTAssertEqual(events[0].id, events[1].id)
    }

    func testStreamWritesDeltaEventsThatCanBeTailed() async throws {
        let fileURL = makeTemporaryFileURL()
        let writer = LLMDebugTraceWriter(fileURL: fileURL)
        let request = ChatCompletionRequest(
            model: "/test.gguf",
            messages: [
                ChatMessage(role: "user", content: "Stream user prompt"),
            ],
            temperature: 0.7,
            max_completion_tokens: 256,
            stream: true
        )

        let sessionID = try await writer.beginChatRequest(
            transport: "stream",
            request: request,
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
