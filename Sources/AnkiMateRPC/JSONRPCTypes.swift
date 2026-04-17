// JSON-RPC 2.0 base types for communication between anki-mate app and inference server.

import Foundation

// MARK: - JSON-RPC 2.0 Request

public struct JSONRPCRequest<Params: Encodable>: Encodable, Sendable where Params: Sendable {
    public let jsonrpc: String = "2.0"
    public let method: String
    public let params: Params
    public let id: Int

    public init(method: String, params: Params, id: Int) {
        self.method = method
        self.params = params
        self.id = id
    }
}

// MARK: - JSON-RPC 2.0 Response

public struct JSONRPCResponse<Result: Decodable>: Decodable, Sendable where Result: Sendable {
    public let jsonrpc: String
    public let result: Result?
    public let error: JSONRPCError?
    public let id: Int?
}

public struct JSONRPCError: Codable, Sendable, Error, LocalizedError {
    public let code: Int
    public let message: String
    public let data: String?

    public init(code: Int, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    // Standard JSON-RPC error codes
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")

    // Application-defined error codes (-32000 to -32099)
    public static func modelNotLoaded() -> JSONRPCError {
        JSONRPCError(code: -32001, message: "No model loaded")
    }

    public static func modelLoadFailed(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: -32002, message: "Model load failed", data: detail)
    }

    public static func inferenceError(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: -32003, message: "Inference error", data: detail)
    }
}

// MARK: - Encodable response helper (for server side)

public struct JSONRPCResponseEnvelope: Encodable, Sendable {
    public let jsonrpc: String = "2.0"
    public let result: AnyCodable?
    public let error: JSONRPCError?
    public let id: Int?

    public static func success<T: Encodable & Sendable>(_ value: T, id: Int) -> JSONRPCResponseEnvelope {
        JSONRPCResponseEnvelope(result: AnyCodable(value), error: nil, id: id)
    }

    public static func failure(_ error: JSONRPCError, id: Int?) -> JSONRPCResponseEnvelope {
        JSONRPCResponseEnvelope(result: nil, error: error, id: id)
    }
}

/// Type-erased Codable wrapper for encoding heterogeneous result types.
public struct AnyCodable: Encodable, Sendable {
    private let _encode: @Sendable (Encoder) throws -> Void

    public init<T: Encodable & Sendable>(_ value: T) {
        _encode = { encoder in try value.encode(to: encoder) }
    }

    public func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - Raw request for server-side decoding (method dispatch before knowing params type)

public struct JSONRPCRawRequest: Decodable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONRPCRawParams?
    public let id: Int?
}

/// Raw params container that defers decoding until the method is known.
public struct JSONRPCRawParams: Decodable, Sendable {
    public let data: Data

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Re-encode the raw JSON to Data for later decoding
        // We use a custom approach: capture the raw JSON
        if let dict = try? container.decode([String: JSONValue].self) {
            self.data = try JSONEncoder().encode(dict)
        } else if let arr = try? container.decode([JSONValue].self) {
            self.data = try JSONEncoder().encode(arr)
        } else {
            self.data = Data()
        }
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// Helper for preserving arbitrary JSON values during re-encoding.
public enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
