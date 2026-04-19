// JSON-RPC client — sends requests to the local inference server via URLSession.

import Foundation
import AnkiMateRPC
import os

public enum RPCClientError: Error, LocalizedError {
    case serverNotRunning
    case httpError(statusCode: Int)
    case decodingError(String)
    case rpcError(JSONRPCError)

    public var errorDescription: String? {
        switch self {
        case .serverNotRunning: return "Inference server is not running"
        case .httpError(let code): return "HTTP error: \(code)"
        case .decodingError(let msg): return "Failed to decode response: \(msg)"
        case .rpcError(let err): return err.detailedDescription
        }
    }
}

public actor RPCClient {
    private let session: URLSession
    private var nextId = 1
    private let logger = Logger(subsystem: "AnkiMateLLM", category: "RPCClient")
    private let debugTraceWriter: LLMDebugTraceWriter

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120 // generation can be slow
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.debugTraceWriter = LLMDebugTraceWriter.shared
    }

    /// Call a JSON-RPC method.
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

        let debugSessionID: UUID?
        if LLMDebugSettings.isStreamDebugEnabled,
           method == RPCMethod.generate,
           let generateParams = params as? GenerateParams {
            debugSessionID = try? await debugTraceWriter.beginRequest(
                transport: "request-response",
                rpcMethod: method,
                params: generateParams,
                port: port
            )
        } else {
            debugSessionID = nil
        }

        do {
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

            if let debugSessionID, let generateResult = result as? GenerateResult {
                try? await debugTraceWriter.finishRequest(debugSessionID, response: generateResult)
            }

            return result
        } catch {
            if let debugSessionID {
                try? await debugTraceWriter.failRequest(debugSessionID, error: error)
            }
            throw error
        }
    }

    public func streamGenerate(
        params: GenerateParams,
        port: Int,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> GenerateResult {
        let debugEnabled = LLMDebugSettings.isStreamDebugEnabled
        let debugSessionID = debugEnabled
            ? (try? await debugTraceWriter.beginRequest(
                transport: "stream",
                rpcMethod: RPCMethod.generate,
                params: params,
                port: port
            ))
            : nil
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(params)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if debugEnabled {
            logger.info("streamGenerate request sent, port=\(port)")
        }

        do {
            let (bytes, httpResponse) = try await session.bytes(for: urlRequest)
            if let resp = httpResponse as? HTTPURLResponse, resp.statusCode != 200 {
                throw RPCClientError.httpError(statusCode: resp.statusCode)
            }

            var finalTokens = 0
            var finalDuration = 0
            var finalText = ""

            var sawDone = false
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard trimmed.first == "{" else {
                    if debugEnabled {
                        logger.debug("stream line skipped: \(trimmed, privacy: .public)")
                    }
                    continue
                }
                let data = Data(trimmed.utf8)
                let chunk = try decodeStreamChunk(from: data)

                if let error = chunk.error, !error.isEmpty {
                    if debugEnabled {
                        logger.error("stream chunk error: \(error, privacy: .public)")
                    }
                    throw RPCClientError.decodingError(error)
                }

                if let delta = chunk.delta, !delta.isEmpty {
                    finalText += delta
                    onDelta(delta)
                    if let debugSessionID {
                        try? await debugTraceWriter.appendStreamDelta(delta, for: debugSessionID)
                    }
                    if debugEnabled {
                        logger.debug("stream delta len=\(delta.count)")
                    }
                }

                if chunk.done == true {
                    finalTokens = chunk.tokensUsed ?? finalTokens
                    finalDuration = chunk.durationMs ?? finalDuration
                    sawDone = true
                    if debugEnabled {
                        logger.info("stream done tokens=\(finalTokens) durationMs=\(finalDuration)")
                    }
                    break
                }
            }

            if !sawDone && finalText.isEmpty {
                throw RPCClientError.decodingError("Streaming ended without payload")
            }

            let result = GenerateResult(
                text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
                tokensUsed: finalTokens,
                durationMs: finalDuration
            )
            if let debugSessionID {
                try? await debugTraceWriter.finishRequest(debugSessionID, response: result)
            }
            return result
        } catch {
            if let debugSessionID {
                try? await debugTraceWriter.failRequest(debugSessionID, error: error)
            }
            throw error
        }
    }
}

private struct StreamChunk: Codable {
    let delta: String?
    let done: Bool?
    let tokensUsed: Int?
    let durationMs: Int?
    let error: String?
}

private extension RPCClient {
    func decodeStreamChunk(from data: Data) throws -> StreamChunk {
        do {
            return try JSONDecoder().decode(StreamChunk.self, from: data)
        } catch {
            if let envelope = try? JSONDecoder().decode(JSONRPCResponse<GenerateResult>.self, from: data),
               let rpcError = envelope.error {
                if LLMDebugSettings.isStreamDebugEnabled {
                    logger.error("stream rpc error envelope: \(rpcError.message, privacy: .public)")
                }
                throw RPCClientError.rpcError(rpcError)
            }
            throw RPCClientError.decodingError("Invalid stream chunk: \(error.localizedDescription)")
        }
    }
}
