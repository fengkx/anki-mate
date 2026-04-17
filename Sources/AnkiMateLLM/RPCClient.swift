// JSON-RPC client — sends requests to the local inference server via URLSession.

import Foundation
import AnkiMateRPC

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
        case .rpcError(let err): return err.message
        }
    }
}

public actor RPCClient {
    private let session: URLSession
    private var nextId = 1

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120 // generation can be slow
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
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
}
