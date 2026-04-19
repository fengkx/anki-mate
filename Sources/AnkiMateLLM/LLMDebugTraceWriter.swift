import Foundation
import AnkiMateRPC

actor LLMDebugTraceWriter {
    struct ErrorPayload: Codable {
        let type: String
        let message: String
        let detail: String?
        let stack: [String]?
    }

    struct Event: Codable {
        let id: String
        let timestamp: String
        let event: String
        let transport: String
        let rpcMethod: String
        let port: Int
        let params: GenerateParams?
        let delta: String?
        let response: GenerateResult?
        let error: ErrorPayload?
    }

    struct Session {
        let id: UUID
        let transport: String
        let rpcMethod: String
        let port: Int
        let params: GenerateParams
    }

    static let defaultFileURL = URL(fileURLWithPath: "/tmp/anki-mate-llm-debug.jsonl")
    static let shared = LLMDebugTraceWriter()

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let fileURL: URL
    private let fileManager: FileManager
    private var sessions: [UUID: Session] = [:]

    init(
        fileURL: URL = defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func beginRequest(
        transport: String,
        rpcMethod: String,
        params: GenerateParams,
        port: Int
    ) throws -> UUID {
        let session = Session(
            id: UUID(),
            transport: transport,
            rpcMethod: rpcMethod,
            port: port,
            params: params
        )
        sessions[session.id] = session
        try append(
            Event(
                id: session.id.uuidString,
                timestamp: Self.dateFormatter.string(from: Date()),
                event: "request_started",
                transport: transport,
                rpcMethod: rpcMethod,
                port: port,
                params: params,
                delta: nil,
                response: nil,
                error: nil
            )
        )
        return session.id
    }

    func appendStreamDelta(_ delta: String, for sessionID: UUID) throws {
        guard let session = sessions[sessionID] else { return }
        try append(
            Event(
                id: session.id.uuidString,
                timestamp: Self.dateFormatter.string(from: Date()),
                event: "stream_delta",
                transport: session.transport,
                rpcMethod: session.rpcMethod,
                port: session.port,
                params: nil,
                delta: delta,
                response: nil,
                error: nil
            )
        )
    }

    func finishRequest(_ sessionID: UUID, response: GenerateResult) throws {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        try append(
            Event(
                id: session.id.uuidString,
                timestamp: Self.dateFormatter.string(from: Date()),
                event: "request_finished",
                transport: session.transport,
                rpcMethod: session.rpcMethod,
                port: session.port,
                params: nil,
                delta: nil,
                response: response,
                error: nil
            )
        )
    }

    func failRequest(_ sessionID: UUID, error: Error) throws {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        try append(
            Event(
                id: session.id.uuidString,
                timestamp: Self.dateFormatter.string(from: Date()),
                event: "request_failed",
                transport: session.transport,
                rpcMethod: session.rpcMethod,
                port: session.port,
                params: nil,
                delta: nil,
                response: nil,
                error: Self.makeErrorPayload(from: error)
            )
        )
    }

    private func append(_ event: Event) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private static func makeErrorPayload(from error: Error) -> ErrorPayload {
        if let rpcClientError = error as? RPCClientError {
            switch rpcClientError {
            case .rpcError(let rpcError):
                return ErrorPayload(
                    type: "JSONRPCError",
                    message: rpcError.message,
                    detail: rpcError.data,
                    stack: rpcError.data?
                        .split(whereSeparator: \.isNewline)
                        .map(String.init)
                        .filter { $0.contains("/") || $0.hasPrefix("0") || $0.contains("Thread.callStackSymbols") }
                        .nilIfEmpty
                )
            case .serverNotRunning:
                return ErrorPayload(type: "RPCClientError", message: "Inference server is not running", detail: nil, stack: nil)
            case .httpError(let statusCode):
                return ErrorPayload(type: "RPCClientError", message: "HTTP error: \(statusCode)", detail: nil, stack: nil)
            case .decodingError(let message):
                return ErrorPayload(type: "RPCClientError", message: "Failed to decode response", detail: message, stack: nil)
            }
        }

        return ErrorPayload(
            type: String(reflecting: Swift.type(of: error)),
            message: error.localizedDescription,
            detail: String(reflecting: error),
            stack: nil
        )
    }
}

private extension Array {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
