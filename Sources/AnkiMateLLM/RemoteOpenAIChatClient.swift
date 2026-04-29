import AnkiMateRPC
import Foundation
import os

actor RemoteOpenAIChatClient {
    struct Configuration: Sendable, Equatable {
        let baseURL: String
        let modelID: String
        let apiKey: String

        init(baseURL: String, modelID: String, apiKey: String) {
            self.baseURL = baseURL
            self.modelID = modelID
            self.apiKey = apiKey
        }

        var chatCompletionsURL: URL? {
            var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while normalized.hasSuffix("/") {
                normalized.removeLast()
            }
            return URL(string: normalized)?.appendingPathComponent("v1/chat/completions")
        }
    }

    private let session: URLSession
    private let debugTraceWriter: LLMDebugTraceWriter
    private let logger = Logger(subsystem: "AnkiMateLLM", category: "RemoteOpenAIChatClient")

    init(
        session: URLSession? = nil,
        requestTimeoutSeconds: TimeInterval = 120,
        debugTraceWriter: LLMDebugTraceWriter = .shared
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = requestTimeoutSeconds
            configuration.timeoutIntervalForResource = max(requestTimeoutSeconds + 60, requestTimeoutSeconds)
            self.session = URLSession(configuration: configuration)
        }
        self.debugTraceWriter = debugTraceWriter
    }

    func chatCompletion(
        request: ChatCompletionRequest,
        configuration: Configuration
    ) async throws -> ChatCompletionResponse {
        let sanitizedRequest = Self.remoteRequest(from: request, modelID: configuration.modelID, stream: false)
        let debugSessionID: UUID?
        if LLMDebugSettings.isStreamDebugEnabled {
            debugSessionID = try? await debugTraceWriter.beginChatRequest(
                transport: "remote-request-response",
                request: sanitizedRequest,
                port: 0
            )
        } else {
            debugSessionID = nil
        }

        do {
            var urlRequest = try makeURLRequest(request: sanitizedRequest, configuration: configuration)
            urlRequest.httpBody = try JSONEncoder().encode(sanitizedRequest)

            let (data, httpResponse) = try await session.data(for: urlRequest)
            if let resp = httpResponse as? HTTPURLResponse, resp.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw RPCClientError.upstreamError("HTTP \(resp.statusCode): \(body)")
            }

            let response: ChatCompletionResponse
            do {
                response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            } catch {
                throw RPCClientError.decodingError(error.localizedDescription)
            }

            if let debugSessionID {
                try? await debugTraceWriter.finishChatRequest(debugSessionID, response: response)
            }
            return response
        } catch {
            if let debugSessionID {
                try? await debugTraceWriter.failRequest(debugSessionID, error: error)
            }
            throw error
        }
    }

    func chatCompletionStream(
        request: ChatCompletionRequest,
        configuration: Configuration,
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> ChatCompletionResponse {
        let sanitizedRequest = Self.remoteRequest(from: request, modelID: configuration.modelID, stream: true)
        let debugEnabled = LLMDebugSettings.isStreamDebugEnabled
        let debugSessionID: UUID?
        if debugEnabled {
            debugSessionID = try? await debugTraceWriter.beginChatRequest(
                transport: "remote-stream",
                request: sanitizedRequest,
                port: 0
            )
        } else {
            debugSessionID = nil
        }

        do {
            var urlRequest = try makeURLRequest(request: sanitizedRequest, configuration: configuration)
            urlRequest.httpBody = try JSONEncoder().encode(sanitizedRequest)

            let (bytes, httpResponse) = try await session.bytes(for: urlRequest)
            if let resp = httpResponse as? HTTPURLResponse, resp.statusCode != 200 {
                let body = try await RPCClient.readErrorBody(from: bytes, limit: 4096)
                throw RPCClientError.upstreamError("HTTP \(resp.statusCode): \(body)")
            }

            let response = try await Self.accumulateStream(
                bytes: bytes,
                debugEnabled: debugEnabled,
                debugSessionID: debugSessionID,
                debugTraceWriter: debugTraceWriter,
                logger: logger,
                onDelta: onDelta,
                onReasoningDelta: onReasoningDelta
            )

            if let debugSessionID {
                try? await debugTraceWriter.finishChatRequest(debugSessionID, response: response)
            }
            return response
        } catch {
            if let debugSessionID {
                try? await debugTraceWriter.failRequest(debugSessionID, error: error)
            }
            throw error
        }
    }

    func testConnection(configuration: Configuration) async throws {
        _ = try await chatCompletion(
            request: ChatCompletionRequest(
                model: configuration.modelID,
                messages: [ChatMessage(role: "user", content: "Reply with OK.")],
                temperature: 0,
                max_completion_tokens: 4
            ),
            configuration: configuration
        )
    }

    static func remoteRequest(
        from request: ChatCompletionRequest,
        modelID: String,
        stream: Bool?
    ) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: modelID,
            messages: request.messages,
            temperature: request.temperature,
            max_completion_tokens: request.max_completion_tokens,
            stream: stream ?? request.stream,
            tools: request.tools,
            tool_choice: request.tool_choice,
            parallel_tool_calls: request.parallel_tool_calls,
            response_format: request.response_format
        )
    }

    private func makeURLRequest(
        request: ChatCompletionRequest,
        configuration: Configuration
    ) throws -> URLRequest {
        guard let url = configuration.chatCompletionsURL else {
            throw RPCClientError.upstreamError("Invalid BYOK base URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    private static func accumulateStream(
        bytes: URLSession.AsyncBytes,
        debugEnabled: Bool,
        debugSessionID: UUID?,
        debugTraceWriter: LLMDebugTraceWriter,
        logger: Logger,
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)?
    ) async throws -> ChatCompletionResponse {
        var accumulatedContent = ""
        var accumulatedReasoning = ""
        var accumulatedRawContent = ""
        var accumulatedToolCalls: [ChatToolCall] = []
        var finishReason: String?
        var usage: ChatCompletionResponse.Usage?
        var lastId: String?
        var lastModel: String?

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data: ") else { continue }
            let payload = String(trimmed.dropFirst(6))
            if payload == "[DONE]" {
                break
            }

            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatCompletionStreamChunk.self, from: chunkData)
            else {
                if debugEnabled {
                    logger.debug("remote stream chunk decode failed: \(payload, privacy: .public)")
                }
                continue
            }

            lastId = chunk.id ?? lastId
            lastModel = chunk.model ?? lastModel
            usage = chunk.usage ?? usage

            for choice in chunk.choices {
                finishReason = choice.finish_reason ?? finishReason
                if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                    accumulatedReasoning += reasoning
                    onReasoningDelta?(reasoning)
                }
                if let toolCalls = choice.delta.tool_calls, !toolCalls.isEmpty {
                    accumulatedToolCalls = RPCClient.mergeStreamToolCalls(accumulatedToolCalls, with: toolCalls)
                }
                guard let content = choice.delta.content?.plainText, !content.isEmpty else {
                    continue
                }
                accumulatedRawContent += content
                let split = RPCClient.splitThinkingTaggedContent(accumulatedRawContent)
                let newVisible = String(split.visible.dropFirst(accumulatedContent.count))
                accumulatedContent = split.visible
                accumulatedReasoning = split.reasoning.isEmpty ? accumulatedReasoning : split.reasoning
                if !newVisible.isEmpty {
                    onDelta(newVisible)
                    if let debugSessionID {
                        try? await debugTraceWriter.appendStreamDelta(newVisible, for: debugSessionID)
                    }
                }
            }
        }

        let message = ChatMessage(
            role: "assistant",
            content: accumulatedContent.isEmpty ? nil : .text(accumulatedContent),
            reasoning_content: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning,
            tool_calls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
        )
        return ChatCompletionResponse(
            id: lastId ?? UUID().uuidString,
            model: lastModel,
            choices: [
                ChatCompletionResponse.Choice(
                    index: 0,
                    message: message,
                    finish_reason: finishReason
                )
            ],
            usage: usage
        )
    }
}

public enum BYOKConnectionTester {
    public static func test(credentials: BYOKCredentials) async throws {
        guard credentials.isConfigured else {
            throw LLMServiceError.byokNotConfigured
        }
        let client = RemoteOpenAIChatClient(requestTimeoutSeconds: 30)
        try await client.testConnection(
            configuration: .init(
                baseURL: credentials.baseURL,
                modelID: credentials.modelID,
                apiKey: credentials.apiKey
            )
        )
    }
}
