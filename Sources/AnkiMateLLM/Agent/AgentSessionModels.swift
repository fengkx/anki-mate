import Foundation

public struct AgentChatSession: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let wordItemID: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int
    public var preferences: AgentSessionPreferences

    public init(
        id: UUID = UUID(),
        wordItemID: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = Self.currentSchemaVersion,
        preferences: AgentSessionPreferences = .init()
    ) {
        self.id = id
        self.wordItemID = wordItemID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
        self.preferences = preferences
    }
}

public struct AgentSessionPreferences: Codable, Equatable, Sendable {
    public var autoExecuteReadTools: Bool
    public var maxHistoryMessages: Int
    public var maxHistoryAgeDays: Int

    public init(
        autoExecuteReadTools: Bool = true,
        maxHistoryMessages: Int = 500,
        maxHistoryAgeDays: Int = 90
    ) {
        self.autoExecuteReadTools = autoExecuteReadTools
        self.maxHistoryMessages = maxHistoryMessages
        self.maxHistoryAgeDays = maxHistoryAgeDays
    }
}

public struct AgentChatMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let ordinal: Int
    public let role: Role
    public let createdAt: Date
    public var status: Status
    public var content: MessageContent
    public var supersededBy: UUID?
    public var interrupted: Bool

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        ordinal: Int,
        role: Role,
        createdAt: Date = Date(),
        status: Status = .completed,
        content: MessageContent,
        supersededBy: UUID? = nil,
        interrupted: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.ordinal = ordinal
        self.role = role
        self.createdAt = createdAt
        self.status = status
        self.content = content
        self.supersededBy = supersededBy
        self.interrupted = interrupted
    }

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        case tool
        case system
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case streaming
        case completed
        case canceled
        case failed
    }
}

public struct AgentAttachment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: Kind
    public let mimeType: String
    public let fileName: String
    public let relativePath: String
    public let byteSize: Int64
    public let width: Int?
    public let height: Int?
    public let extractedTextPreview: String?
    public let characterCount: Int?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        mimeType: String,
        fileName: String,
        relativePath: String,
        byteSize: Int64,
        width: Int? = nil,
        height: Int? = nil,
        extractedTextPreview: String? = nil,
        characterCount: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.fileName = fileName
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.extractedTextPreview = extractedTextPreview
        self.characterCount = characterCount
    }

    public enum Kind: String, Codable, Sendable {
        case image
        case textFile
    }
}

public enum MessageContent: Codable, Equatable, Sendable {
    case text(String, reasoning: String? = nil)
    case userInput(text: String, attachments: [AgentAttachment])
    case toolCall(name: String, argsJSON: String)
    case toolResult(name: String, resultJSON: String, truncated: Bool)
    case actionProposal(ProposalRecord)
    case summary(String, supersededCount: Int)
    case error(message: String, recoverable: Bool)
    case layoutRequestDeclined(userText: String, detectedKind: DeclinedRequestKind)

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case name
        case argsJSON
        case resultJSON
        case truncated
        case proposal
        case supersededCount
        case message
        case recoverable
        case reasoning
        case userText
        case detectedKind
        case attachments
    }

    private enum Kind: String, Codable {
        case text
        case userInput = "user_input"
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case actionProposal = "proposal"
        case summary
        case error
        case layoutRequestDeclined = "layout_request_declined"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(
                try container.decode(String.self, forKey: .text),
                reasoning: try container.decodeIfPresent(String.self, forKey: .reasoning)
            )
        case .userInput:
            self = .userInput(
                text: try container.decode(String.self, forKey: .text),
                attachments: try container.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
            )
        case .toolCall:
            self = .toolCall(
                name: try container.decode(String.self, forKey: .name),
                argsJSON: try container.decode(String.self, forKey: .argsJSON)
            )
        case .toolResult:
            self = .toolResult(
                name: try container.decode(String.self, forKey: .name),
                resultJSON: try container.decode(String.self, forKey: .resultJSON),
                truncated: try container.decode(Bool.self, forKey: .truncated)
            )
        case .actionProposal:
            self = .actionProposal(try container.decode(ProposalRecord.self, forKey: .proposal))
        case .summary:
            self = .summary(
                try container.decode(String.self, forKey: .text),
                supersededCount: try container.decode(Int.self, forKey: .supersededCount)
            )
        case .error:
            self = .error(
                message: try container.decode(String.self, forKey: .message),
                recoverable: try container.decode(Bool.self, forKey: .recoverable)
            )
        case .layoutRequestDeclined:
            self = .layoutRequestDeclined(
                userText: try container.decode(String.self, forKey: .userText),
                detectedKind: try container.decode(DeclinedRequestKind.self, forKey: .detectedKind)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let reasoning):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
            if let reasoning {
                try container.encode(reasoning, forKey: .reasoning)
            }
        case .userInput(let text, let attachments):
            try container.encode(Kind.userInput, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(attachments, forKey: .attachments)
        case .toolCall(let name, let argsJSON):
            try container.encode(Kind.toolCall, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(argsJSON, forKey: .argsJSON)
        case .toolResult(let name, let resultJSON, let truncated):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(resultJSON, forKey: .resultJSON)
            try container.encode(truncated, forKey: .truncated)
        case .actionProposal(let proposal):
            try container.encode(Kind.actionProposal, forKey: .kind)
            try container.encode(proposal, forKey: .proposal)
        case .summary(let text, let supersededCount):
            try container.encode(Kind.summary, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(supersededCount, forKey: .supersededCount)
        case .error(let message, let recoverable):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .message)
            try container.encode(recoverable, forKey: .recoverable)
        case .layoutRequestDeclined(let userText, let detectedKind):
            try container.encode(Kind.layoutRequestDeclined, forKey: .kind)
            try container.encode(userText, forKey: .userText)
            try container.encode(detectedKind, forKey: .detectedKind)
        }
    }
}

public extension MessageContent {
    var isUserAuthoredInput: Bool {
        switch self {
        case .text, .userInput:
            return true
        default:
            return false
        }
    }
}

public enum DeclinedRequestKind: String, Codable, Sendable {
    case layout
    case style
    case template
    case unknown
}

public struct ProposalRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ProposalKind
    public let operation: Operation
    public let payloadJSON: String
    public let diffSummary: String
    public let rationale: String?
    public var decision: Decision
    public var decidedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: ProposalKind,
        operation: Operation,
        payloadJSON: String,
        diffSummary: String,
        rationale: String? = nil,
        decision: Decision = .pending,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.operation = operation
        self.payloadJSON = payloadJSON
        self.diffSummary = diffSummary
        self.rationale = rationale
        self.decision = decision
        self.decidedAt = decidedAt
    }

    public enum ProposalKind: String, Codable, Sendable {
        case usageCue = "usage_cue"
        case example
        case recallDraft = "recall_draft"
        case pitfall
        case mnemonic
        case collocation
        case deleteAccepted = "delete_accepted"
    }

    public enum Operation: Codable, Equatable, Sendable {
        case add
        case replace(targetID: String)
        case delete(targetID: String)

        public var isDelete: Bool {
            if case .delete = self {
                return true
            }
            return false
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case targetID
        }

        private enum Kind: String, Codable {
            case add
            case replace
            case delete
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .type) {
            case .add:
                self = .add
            case .replace:
                self = .replace(targetID: try container.decode(String.self, forKey: .targetID))
            case .delete:
                self = .delete(targetID: try container.decode(String.self, forKey: .targetID))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .add:
                try container.encode(Kind.add, forKey: .type)
            case .replace(let targetID):
                try container.encode(Kind.replace, forKey: .type)
                try container.encode(targetID, forKey: .targetID)
            case .delete(let targetID):
                try container.encode(Kind.delete, forKey: .type)
                try container.encode(targetID, forKey: .targetID)
            }
        }
    }

    public enum Decision: String, Codable, Sendable {
        case pending
        case applied
        case dismissed
    }
}
