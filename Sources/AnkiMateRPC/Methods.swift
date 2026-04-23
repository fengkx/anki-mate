// JSON-RPC method definitions: parameter and result types for each RPC method.

import Foundation

// MARK: - Method Names

public enum RPCMethod {
    public static let health = "health"
    public static let loadModel = "loadModel"
    public static let unloadModel = "unloadModel"
    public static let shutdown = "shutdown"
}

// MARK: - Shared LLM Types

public struct LLMMessage: Codable, Sendable, Equatable {
    public let role: LLMMessageRole
    public let content: LLMMessageContent

    public init(role: LLMMessageRole, content: String) {
        self.role = role
        self.content = .text(content)
    }

    public init(role: LLMMessageRole, content: LLMMessageContent) {
        self.role = role
        self.content = content
    }
}

public enum LLMMessageRole: String, Codable, Sendable, Equatable {
    case system
    case user
    case assistant
    case tool
}

public enum LLMMessageContent: Codable, Sendable, Equatable {
    case text(String)
    case parts([LLMMessageContentPart])

    public var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.compactMap { part in
                if case .text(let text) = part {
                    return text
                }
                return nil
            }.joined(separator: "\n\n")
        }
    }

    public var isEmpty: Bool {
        plainText.isEmpty
    }

    public func contains(_ other: String) -> Bool {
        plainText.contains(other)
    }

    public func hasPrefix(_ prefix: String) -> Bool {
        plainText.hasPrefix(prefix)
    }

    public var parts: [LLMMessageContentPart] {
        switch self {
        case .text(let text):
            return [.text(text)]
        case .parts(let parts):
            return parts
        }
    }
}

public enum LLMMessageContentPart: Codable, Sendable, Equatable {
    case text(String)
    case imageURL(String)

    public var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .imageURL:
            return ""
        }
    }
}

public struct LLMToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?
    public let parameters: JSONValue?

    public init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// OpenAI-style tool call emitted by the model.
/// `arguments` holds the decoded JSON payload for the tool call.
public struct LLMToolCall: Codable, Sendable, Equatable {
    public let id: String?
    public let name: String
    public let arguments: JSONValue

    public init(id: String? = nil, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public typealias JSONSchema = JSONValue

public struct LLMResponseFormat: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case text
        case json
        case jsonSchema = "json_schema"
    }

    public let kind: Kind
    public let schema: JSONValue?
    public let strict: Bool?

    public init(kind: Kind, schema: JSONSchema? = nil, strict: Bool? = nil) {
        self.kind = kind
        self.schema = schema
        self.strict = strict
    }
}

// MARK: - health

public struct HealthParams: Codable, Sendable {
    public init() {}
}

public struct HealthResult: Codable, Sendable {
    public let status: ServerStatus
    public let modelId: String?
    public let uptimeSeconds: Int
    /// Port of the internal llama-server child process. Clients send chat completion
    /// requests directly to this port instead of going through the control-plane proxy.
    public let inferencePort: Int?

    public init(status: ServerStatus, modelId: String?, uptimeSeconds: Int, inferencePort: Int? = nil) {
        self.status = status
        self.modelId = modelId
        self.uptimeSeconds = uptimeSeconds
        self.inferencePort = inferencePort
    }
}

public enum ServerStatus: String, Codable, Sendable {
    case ready = "ready"
    case loadingModel = "loading_model"
    case noModel = "no_model"
}

// MARK: - loadModel

public struct LoadModelParams: Codable, Sendable {
    public let modelPath: String
    public let mmprojPath: String?
    public let contextSize: Int
    public let gpuLayers: Int

    public init(modelPath: String, mmprojPath: String? = nil, contextSize: Int = 4096, gpuLayers: Int = 99) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.contextSize = contextSize
        self.gpuLayers = gpuLayers
    }
}

public struct LoadModelResult: Codable, Sendable {
    public let ok: Bool

    public init(ok: Bool = true) { self.ok = ok }
}

// MARK: - unloadModel

public struct UnloadModelParams: Codable, Sendable {
    public init() {}
}

public struct UnloadModelResult: Codable, Sendable {
    public let ok: Bool

    public init(ok: Bool = true) { self.ok = ok }
}

// MARK: - GenerateResult (internal convenience type for LLMService/AgentSession)

public struct GenerateResult: Codable, Sendable {
    public let text: String
    public let tokensUsed: Int
    public let durationMs: Int
    public let finishReason: String?
    public let toolCalls: [LLMToolCall]?
    public let reasoning: String?

    public init(
        text: String,
        tokensUsed: Int,
        durationMs: Int,
        finishReason: String? = nil,
        toolCalls: [LLMToolCall]? = nil,
        reasoning: String? = nil
    ) {
        self.text = text
        self.tokensUsed = tokensUsed
        self.durationMs = durationMs
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.reasoning = reasoning
    }
}

// MARK: - shutdown

public struct ShutdownParams: Codable, Sendable {
    public init() {}
}

public struct ShutdownResult: Codable, Sendable {
    public let ok: Bool

    public init(ok: Bool = true) { self.ok = ok }
}
