// OpenAI-compatible chat completion types.
//
// Shared between the server (proxy) and client (RPCClient).
// Matches the OpenAI `/v1/chat/completions` wire format.

import Foundation

// MARK: - Request

public struct ChatCompletionRequest: Codable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Float?
    public var max_completion_tokens: Int?
    public var stream: Bool?
    public var tools: [ChatTool]?
    public var tool_choice: JSONValue?
    public var parallel_tool_calls: Bool?
    public var response_format: ChatResponseFormat?

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Float? = nil,
        max_completion_tokens: Int? = nil,
        stream: Bool? = nil,
        tools: [ChatTool]? = nil,
        tool_choice: JSONValue? = nil,
        parallel_tool_calls: Bool? = nil,
        response_format: ChatResponseFormat? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.max_completion_tokens = max_completion_tokens
        self.stream = stream
        self.tools = tools
        self.tool_choice = tool_choice
        self.parallel_tool_calls = parallel_tool_calls
        self.response_format = response_format
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String?
    public var content: ChatMessageContent?
    public var reasoning_content: String?
    public var tool_calls: [ChatToolCall]?
    public var tool_call_id: String?

    public init(
        role: String?,
        content: String,
        reasoning_content: String? = nil,
        tool_calls: [ChatToolCall]? = nil,
        tool_call_id: String? = nil
    ) {
        self.role = role
        self.content = .text(content)
        self.reasoning_content = reasoning_content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }

    public init(
        role: String? = nil,
        content: ChatMessageContent?,
        reasoning_content: String? = nil,
        tool_calls: [ChatToolCall]? = nil,
        tool_call_id: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoning_content = reasoning_content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }
}

public enum ChatMessageContent: Codable, Sendable, Equatable {
    case text(String)
    case parts([ChatMessageContentPart])

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

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .parts(try container.decode([ChatMessageContentPart].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

public enum ChatMessageContentPart: Codable, Sendable, Equatable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private enum ImageURLKeys: String, CodingKey {
        case url
    }

    private enum Kind: String, Codable {
        case text
        case imageURL = "image_url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .imageURL:
            let imageContainer = try container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            self = .imageURL(try imageContainer.decode(String.self, forKey: .url))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode(Kind.imageURL, forKey: .type)
            var imageContainer = container.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageURL)
            try imageContainer.encode(url, forKey: .url)
        }
    }
}

public struct ChatToolCall: Codable, Sendable, Equatable {
    public let index: Int?
    public let id: String?
    public let type: String?
    public let function: ChatToolCallFunction

    public init(index: Int? = nil, id: String? = nil, type: String? = "function", function: ChatToolCallFunction) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ChatToolCallFunction: Codable, Sendable, Equatable {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
    }
}

public struct ChatTool: Codable, Sendable, Equatable {
    public let type: String
    public let function: ChatFunction

    public init(type: String = "function", function: ChatFunction) {
        self.type = type
        self.function = function
    }
}

public struct ChatFunction: Codable, Sendable, Equatable {
    public let name: String
    public let description: String?
    public let parameters: JSONValue?

    public init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatResponseFormat: Codable, Sendable, Equatable {
    public let type: String
    public let json_schema: ChatJSONSchemaSpec?

    public init(type: String, json_schema: ChatJSONSchemaSpec? = nil) {
        self.type = type
        self.json_schema = json_schema
    }
}

public struct ChatJSONSchemaSpec: Codable, Sendable, Equatable {
    public let name: String
    public let schema: JSONValue
    public let strict: Bool?

    public init(name: String, schema: JSONValue, strict: Bool? = nil) {
        self.name = name
        self.schema = schema
        self.strict = strict
    }
}

// MARK: - Response

public struct ChatCompletionResponse: Codable, Sendable {
    public let id: String?
    public let object: String?
    public let created: Int?
    public let model: String?
    public let choices: [Choice]
    public let usage: Usage?

    public init(
        id: String? = nil,
        object: String? = nil,
        created: Int? = nil,
        model: String? = nil,
        choices: [Choice],
        usage: Usage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
    }

    public struct Choice: Codable, Sendable {
        public let index: Int?
        public let message: ChatMessage
        public let finish_reason: String?

        public init(index: Int? = nil, message: ChatMessage, finish_reason: String? = nil) {
            self.index = index
            self.message = message
            self.finish_reason = finish_reason
        }
    }

    public struct Usage: Codable, Sendable {
        public let prompt_tokens: Int?
        public let completion_tokens: Int?
        public let total_tokens: Int?

        public init(prompt_tokens: Int? = nil, completion_tokens: Int? = nil, total_tokens: Int? = nil) {
            self.prompt_tokens = prompt_tokens
            self.completion_tokens = completion_tokens
            self.total_tokens = total_tokens
        }
    }
}

// MARK: - Streaming Response Chunk

public struct ChatCompletionStreamChunk: Codable, Sendable {
    public let id: String?
    public let object: String?
    public let created: Int?
    public let model: String?
    public let choices: [StreamChoice]
    public let usage: ChatCompletionResponse.Usage?

    public struct StreamChoice: Codable, Sendable {
        public let index: Int?
        public let delta: ChatMessage
        public let finish_reason: String?
    }
}
