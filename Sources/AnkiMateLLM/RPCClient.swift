// RPC + HTTP client for the local inference server.
//
// JSON-RPC: health, loadModel, unloadModel, shutdown (control plane via POST /)
// OpenAI: chatCompletion, chatCompletionStream (data plane via POST /v1/chat/completions)

import Foundation
import AnkiMateRPC
import os

public enum RPCClientError: Error, LocalizedError {
    case serverNotRunning
    case httpError(statusCode: Int)
    case decodingError(String)
    case rpcError(JSONRPCError)
    case upstreamError(String)

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning: return "Inference server is not running"
        case .httpError(let code): return "HTTP error: \(code)"
        case .decodingError(let msg): return "Failed to decode response: \(msg)"
        case .rpcError(let err): return err.detailedDescription
        case .upstreamError(let msg): return "Upstream error: \(msg)"
        }
    }
}

public actor RPCClient {
    public struct Configuration: Sendable, Equatable {
        public let requestTimeoutSeconds: TimeInterval
        public let resourceTimeoutSeconds: TimeInterval

        public init(
            requestTimeoutSeconds: TimeInterval = 120,
            resourceTimeoutSeconds: TimeInterval? = nil
        ) {
            self.requestTimeoutSeconds = requestTimeoutSeconds
            self.resourceTimeoutSeconds = resourceTimeoutSeconds ?? max(requestTimeoutSeconds + 60, requestTimeoutSeconds)
        }
    }

    private let session: URLSession
    private var nextId = 1
    private let logger = Logger(subsystem: "AnkiMateLLM", category: "RPCClient")
    private let debugTraceWriter: LLMDebugTraceWriter
    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.requestTimeoutSeconds
        config.timeoutIntervalForResource = configuration.resourceTimeoutSeconds
        self.session = URLSession(configuration: config)
        self.debugTraceWriter = LLMDebugTraceWriter.shared
        self.configuration = configuration
    }

    static func mergeStreamToolCalls(
        _ existing: [ChatToolCall],
        with deltas: [ChatToolCall]
    ) -> [ChatToolCall] {
        var merged = existing

        for (offset, delta) in deltas.enumerated() {
            let targetIndex = delta.index ?? offset
            if targetIndex < merged.count {
                merged[targetIndex] = mergeToolCallFragment(merged[targetIndex], with: delta, fallbackIndex: targetIndex)
                continue
            }

            while merged.count < targetIndex {
                merged.append(
                    ChatToolCall(
                        index: merged.count,
                        id: nil,
                        type: nil,
                        function: ChatToolCallFunction(name: "", arguments: "")
                    )
                )
            }

            merged.append(
                ChatToolCall(
                    index: targetIndex,
                    id: delta.id,
                    type: delta.type,
                    function: delta.function
                )
            )
        }

        return merged
    }

    private static func mergeToolCallFragment(
        _ existing: ChatToolCall,
        with delta: ChatToolCall,
        fallbackIndex: Int
    ) -> ChatToolCall {
        let mergedName = existing.function.name + delta.function.name
        let mergedArguments = existing.function.arguments + delta.function.arguments

        return ChatToolCall(
            index: existing.index ?? delta.index ?? fallbackIndex,
            id: delta.id ?? existing.id,
            type: delta.type ?? existing.type,
            function: ChatToolCallFunction(name: mergedName, arguments: mergedArguments)
        )
    }

    static func splitThinkingTaggedContent(_ raw: String) -> (visible: String, reasoning: String) {
        let startTag = "<think>"
        let endTag = "</think>"
        var cursor = raw.startIndex
        var visible = ""
        var reasoning = ""
        var insideThink = false

        while cursor < raw.endIndex {
            if insideThink {
                if let endRange = raw.range(of: endTag, range: cursor..<raw.endIndex) {
                    reasoning += String(raw[cursor..<endRange.lowerBound])
                    cursor = endRange.upperBound
                    insideThink = false
                } else {
                    let remainder = String(raw[cursor..<raw.endIndex])
                    reasoning += dropPartialTagSuffix(remainder, tag: endTag)
                    break
                }
            } else {
                if let startRange = raw.range(of: startTag, range: cursor..<raw.endIndex) {
                    visible += String(raw[cursor..<startRange.lowerBound])
                    cursor = startRange.upperBound
                    insideThink = true
                } else {
                    let remainder = String(raw[cursor..<raw.endIndex])
                    visible += dropPartialTagSuffix(remainder, tag: startTag)
                    break
                }
            }
        }

        return (visible, reasoning)
    }

    private static func dropPartialTagSuffix(_ text: String, tag: String) -> String {
        guard !text.isEmpty else { return text }
        for length in stride(from: min(text.count, tag.count - 1), through: 1, by: -1) {
            let suffix = String(text.suffix(length))
            if tag.hasPrefix(suffix) {
                return String(text.dropLast(length))
            }
        }
        return text
    }

    // MARK: - JSON-RPC (Control Plane)

    /// Call a JSON-RPC method (health, loadModel, unloadModel, shutdown).
    public func call<P: Encodable & Sendable, R: Decodable & Sendable>(
        method: String,
        params: P,
        port: Int
    ) async throws -> R {
        let id = nextId
        nextId += 1

        let request = JSONRPCRequest(method: method, params: params, id: id)
        let bodyData = try JSONEncoder().encode(request)

        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await session.data(for: urlRequest)

        if let resp = httpResponse as? HTTPURLResponse, resp.statusCode != 200 {
            throw RPCClientError.httpError(statusCode: resp.statusCode)
        }

        let rpcResponse: JSONRPCResponse<R>
        do {
            rpcResponse = try JSONDecoder().decode(JSONRPCResponse<R>.self, from: data)
        } catch {
            throw RPCClientError.decodingError(error.localizedDescription)
        }

        if let err = rpcResponse.error {
            throw RPCClientError.rpcError(err)
        }

        guard let result = rpcResponse.result else {
            throw RPCClientError.decodingError("Response has neither result nor error")
        }

        return result
    }

    // MARK: - OpenAI Chat Completions (Data Plane)

    /// Non-streaming chat completion.
    public func chatCompletion(
        request: ChatCompletionRequest,
        port: Int
    ) async throws -> ChatCompletionResponse {
        let debugSessionID: UUID?
        if LLMDebugSettings.isStreamDebugEnabled {
            debugSessionID = try? await debugTraceWriter.beginChatRequest(
                transport: "request-response",
                request: request,
                port: port
            )
        } else {
            debugSessionID = nil
        }

        do {
            let bodyData = try JSONEncoder().encode(request)
            var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = bodyData
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

    /// Streaming chat completion via SSE.
    ///
    /// Returns the accumulated response. Calls `onDelta` for each content delta
    /// and `onReasoningDelta` for each reasoning/thinking delta.
    public func chatCompletionStream(
        request: ChatCompletionRequest,
        port: Int,
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> ChatCompletionResponse {
        var streamRequest = request
        streamRequest.stream = true

        let debugEnabled = LLMDebugSettings.isStreamDebugEnabled
        let debugSessionID: UUID?
        if debugEnabled {
            debugSessionID = try? await debugTraceWriter.beginChatRequest(
                transport: "stream",
                request: streamRequest,
                port: port
            )
        } else {
            debugSessionID = nil
        }

        do {
            let bodyData = try JSONEncoder().encode(streamRequest)
            var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = bodyData
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            if debugEnabled {
                logger.info("chatCompletionStream request sent, port=\(port)")
            }

            let (bytes, httpResponse) = try await session.bytes(for: urlRequest)
            if let resp = httpResponse as? HTTPURLResponse, resp.statusCode != 200 {
                throw RPCClientError.httpError(statusCode: resp.statusCode)
            }

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

                // SSE format: "data: {...}" or "data: [DONE]"
                guard trimmed.hasPrefix("data: ") else { continue }
                let payload = String(trimmed.dropFirst(6))

                if payload == "[DONE]" {
                    if debugEnabled {
                        logger.info("stream done")
                    }
                    break
                }

                guard let chunkData = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(ChatCompletionStreamChunk.self, from: chunkData) else {
                    if debugEnabled {
                        logger.debug("stream chunk decode failed: \(payload, privacy: .public)")
                    }
                    continue
                }

                lastId = chunk.id ?? lastId
                lastModel = chunk.model ?? lastModel
                if let u = chunk.usage {
                    usage = u
                }

                if let choice = chunk.choices.first {
                    if let content = choice.delta.content, !content.isEmpty {
                        accumulatedRawContent += content
                        let split = Self.splitThinkingTaggedContent(accumulatedRawContent)
                        let visibleDelta = String(split.visible.dropFirst(accumulatedContent.count))
                        let reasoningDeltaFromContent = String(split.reasoning.dropFirst(accumulatedReasoning.count))

                        if !visibleDelta.isEmpty {
                            accumulatedContent += visibleDelta
                            onDelta(visibleDelta)
                            if let debugSessionID {
                                try? await debugTraceWriter.appendStreamDelta(visibleDelta, for: debugSessionID)
                            }
                        }

                        if !reasoningDeltaFromContent.isEmpty {
                            accumulatedReasoning += reasoningDeltaFromContent
                            onReasoningDelta?(reasoningDeltaFromContent)
                            if let debugSessionID {
                                try? await debugTraceWriter.appendStreamDelta("[reasoning] " + reasoningDeltaFromContent, for: debugSessionID)
                            }
                        }
                    }

                    // Gemma 4 and other reasoning models put thinking output in reasoning_content
                    if let reasoning = choice.delta.reasoning_content, !reasoning.isEmpty {
                        accumulatedReasoning += reasoning
                        onReasoningDelta?(reasoning)
                        if let debugSessionID {
                            try? await debugTraceWriter.appendStreamDelta("[reasoning] " + reasoning, for: debugSessionID)
                        }
                    }

                    if let toolCalls = choice.delta.tool_calls {
                        accumulatedToolCalls = Self.mergeStreamToolCalls(accumulatedToolCalls, with: toolCalls)
                    }

                    if let fr = choice.finish_reason {
                        finishReason = fr
                    }
                }
            }

            // If the model only produced reasoning_content (no regular content),
            // use reasoning as the content so the response isn't empty.
            let finalContent = accumulatedContent.isEmpty ? accumulatedReasoning : accumulatedContent

            let responseMessage = ChatMessage(
                role: "assistant",
                content: finalContent.isEmpty ? nil : finalContent,
                reasoning_content: accumulatedReasoning.isEmpty ? nil : accumulatedReasoning,
                tool_calls: accumulatedToolCalls.isEmpty ? nil : accumulatedToolCalls
            )

            let response = ChatCompletionResponse(
                id: lastId,
                model: lastModel,
                choices: [
                    ChatCompletionResponse.Choice(
                        index: 0,
                        message: responseMessage,
                        finish_reason: finishReason
                    )
                ],
                usage: usage
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
}
