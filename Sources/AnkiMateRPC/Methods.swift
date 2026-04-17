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
    public let maxTokens: Int
    public let temperature: Float

    public init(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 256,
        temperature: Float = 0.7
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct GenerateResult: Codable, Sendable {
    public let text: String
    public let tokensUsed: Int
    public let durationMs: Int

    public init(text: String, tokensUsed: Int, durationMs: Int) {
        self.text = text
        self.tokensUsed = tokensUsed
        self.durationMs = durationMs
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
