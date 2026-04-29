import AnkiMateRPC
import XCTest
@testable import AnkiMateLLM

final class RemoteOpenAIChatClientTests: XCTestCase {
    override func tearDown() {
        RemoteChatURLProtocol.reset()
        super.tearDown()
    }

    func testRequestUsesConfiguredEndpointModelAndBearerToken() async throws {
        let client = makeClient()
        RemoteChatURLProtocol.response = chatResponseData("hello")

        _ = try await client.chatCompletion(
            request: ChatCompletionRequest(
                model: "/local/model.gguf",
                messages: [ChatMessage(role: "user", content: "Hi")],
                temperature: 0.2,
                max_completion_tokens: 12,
                thinking_budget_tokens: 512,
                reasoning_format: "deepseek"
            ),
            configuration: .init(
                baseURL: "https://api.example.com",
                modelID: "remote-model",
                apiKey: "secret-key"
            )
        )

        let request = try XCTUnwrap(RemoteChatURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")

        let body = try XCTUnwrap(RemoteChatURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "remote-model")
        XCTAssertNil(json["thinking_budget_tokens"])
        XCTAssertNil(json["reasoning_format"])
        XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("secret-key") == true)
    }

    func testNonSuccessResponseIncludesBodyInError() async throws {
        let client = makeClient()
        RemoteChatURLProtocol.statusCode = 401
        RemoteChatURLProtocol.response = Data("bad key".utf8)

        do {
            _ = try await client.chatCompletion(
                request: ChatCompletionRequest(model: "ignored", messages: []),
                configuration: .init(baseURL: "https://api.example.com", modelID: "remote-model", apiKey: "secret-key")
            )
            XCTFail("Expected request to fail")
        } catch RPCClientError.upstreamError(let message) {
            XCTAssertTrue(message.contains("401"))
            XCTAssertTrue(message.contains("bad key"))
        }
    }

    func testStreamingResponseAccumulatesServerSentEvents() async throws {
        let client = makeClient()
        RemoteChatURLProtocol.response = Data(
            """
            data: {"id":"chatcmpl-test","model":"remote-model","choices":[{"index":0,"delta":{"role":"assistant","content":"hel"}}]}

            data: {"id":"chatcmpl-test","model":"remote-model","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":"stop"}]}

            data: [DONE]

            """.utf8
        )

        let deltas = LockedDeltas()
        let response = try await client.chatCompletionStream(
            request: ChatCompletionRequest(model: "ignored", messages: []),
            configuration: .init(baseURL: "https://api.example.com", modelID: "remote-model", apiKey: "secret-key"),
            onDelta: { deltas.append($0) }
        )

        XCTAssertEqual(deltas.joined(), "hello")
        XCTAssertEqual(response.choices.first?.message.content?.plainText, "hello")
    }

    private func makeClient() -> RemoteOpenAIChatClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteChatURLProtocol.self]
        return RemoteOpenAIChatClient(session: URLSession(configuration: configuration))
    }

    private func chatResponseData(_ content: String) -> Data {
        Data(
            """
            {"id":"chatcmpl-test","object":"chat.completion","created":1,"model":"remote-model","choices":[{"index":0,"message":{"role":"assistant","content":"\(content)"},"finish_reason":"stop"}]}
            """.utf8
        )
    }
}

private final class LockedDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.joined()
    }
}

private final class RemoteChatURLProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    static var lastBody: Data?
    static var statusCode = 200
    static var response = Data()

    static func reset() {
        lastRequest = nil
        lastBody = nil
        statusCode = 200
        response = Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.flatMap { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 1024)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
