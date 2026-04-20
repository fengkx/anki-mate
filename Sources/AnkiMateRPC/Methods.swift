// JSON-RPC method definitions: parameter and result types for each RPC method.

import Foundation

// MARK: - Method Names

public enum RPCMethod {
    public static let health = "health"
    public static let loadModel = "loadModel"
    public static let unloadModel = "unloadModel"
    public static let generate = "generate"
    public static let shutdown = "shutdown"
}

// MARK: - Shared LLM Types

public struct LLMMessage: Codable, Sendable, Equatable {
    public let role: LLMMessageRole
    public let content: String

    public init(role: LLMMessageRole, content: String) {
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

    public init(status: ServerStatus, modelId: String?, uptimeSeconds: Int) {
        self.status = status
        self.modelId = modelId
        self.uptimeSeconds = uptimeSeconds
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
    public let contextSize: Int
    public let gpuLayers: Int

    public init(modelPath: String, contextSize: Int = 4096, gpuLayers: Int = 99) {
        self.modelPath = modelPath
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

// MARK: - generate

public struct GenerateParams: Codable, Sendable {
    public let prompt: String
    public let systemPrompt: String?
    public let messages: [LLMMessage]?
    public let tools: [LLMToolDefinition]?
    /// OpenAI-style: "auto" | "none" | "required". Only consulted when `tools` is non-empty.
    public let toolChoice: String?
    /// OpenAI-style: whether the model may emit multiple tool calls per turn.
    public let parallelToolCalls: Bool
    public let responseFormat: LLMResponseFormat?
    public let maxTokens: Int
    public let temperature: Float

    public init(
        prompt: String,
        systemPrompt: String? = nil,
        messages: [LLMMessage]? = nil,
        tools: [LLMToolDefinition]? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool = false,
        responseFormat: LLMResponseFormat? = nil,
        maxTokens: Int = 256,
        temperature: Float = 0.7
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.responseFormat = responseFormat
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    // Custom Decodable to keep `parallelToolCalls` optional on the wire.
    // Requests from older clients omit the field; default to false.
    enum CodingKeys: String, CodingKey {
        case prompt, systemPrompt, messages, tools, toolChoice, parallelToolCalls,
             responseFormat, maxTokens, temperature
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try c.decode(String.self, forKey: .prompt)
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.messages = try c.decodeIfPresent([LLMMessage].self, forKey: .messages)
        self.tools = try c.decodeIfPresent([LLMToolDefinition].self, forKey: .tools)
        self.toolChoice = try c.decodeIfPresent(String.self, forKey: .toolChoice)
        self.parallelToolCalls = try c.decodeIfPresent(Bool.self, forKey: .parallelToolCalls) ?? false
        self.responseFormat = try c.decodeIfPresent(LLMResponseFormat.self, forKey: .responseFormat)
        self.maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 256
        self.temperature = try c.decodeIfPresent(Float.self, forKey: .temperature) ?? 0.7
    }
}

public struct GenerateResult: Codable, Sendable {
    public let text: String
    public let tokensUsed: Int
    public let durationMs: Int
    public let finishReason: String?
    public let toolCalls: [LLMToolCall]?

    public init(
        text: String,
        tokensUsed: Int,
        durationMs: Int,
        finishReason: String? = nil,
        toolCalls: [LLMToolCall]? = nil
    ) {
        self.text = text
        self.tokensUsed = tokensUsed
        self.durationMs = durationMs
        self.finishReason = finishReason
        self.toolCalls = toolCalls
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
