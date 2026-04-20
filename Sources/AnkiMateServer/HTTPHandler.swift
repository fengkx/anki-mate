// HTTP handler for the JSON-RPC server.
// All requests go to POST / — parsed as JSON-RPC 2.0, dispatched to RPCDispatcher.

import Foundation
import NIOCore
import NIOHTTP1
import AnkiMateRPC

final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let dispatcher: RPCDispatcher
    private let startTime: Date
    private let shutdownCallback: () -> Void

    private var requestBody = ByteBuffer()
    private var requestHead: HTTPRequestHead?

    init(dispatcher: RPCDispatcher, startTime: Date, shutdownCallback: @escaping () -> Void) {
        self.dispatcher = dispatcher
        self.startTime = startTime
        self.shutdownCallback = shutdownCallback
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            requestBody.clear()

        case .body(var body):
            requestBody.writeBuffer(&body)

        case .end:
            handleRequest(context: context)
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else { return }

        // Only accept POST / or /stream
        guard head.method == .POST, head.uri == "/" || head.uri == "/stream" else {
            sendErrorResponse(
                context: context,
                status: .notFound,
                rpcError: .methodNotFound,
                id: nil
            )
            return
        }

        guard requestBody.readableBytes > 0 else {
            sendErrorResponse(
                context: context,
                status: .badRequest,
                rpcError: .parseError,
                id: nil
            )
            return
        }

        let bodyData: Data
        if let bytes = requestBody.getBytes(at: requestBody.readerIndex, length: requestBody.readableBytes) {
            bodyData = Data(bytes)
        } else {
            sendErrorResponse(
                context: context,
                status: .badRequest,
                rpcError: .parseError,
                id: nil
            )
            return
        }

        if head.uri == "/stream" {
            handleStreamRequest(context: context, bodyData: bodyData)
            return
        }

        // Decode the raw JSON-RPC request
        let rawRequest: JSONRPCRawRequest
        do {
            rawRequest = try JSONDecoder().decode(JSONRPCRawRequest.self, from: bodyData)
        } catch {
            sendErrorResponse(
                context: context,
                status: .badRequest,
                rpcError: JSONRPCError(code: -32700, message: "Parse error: \(error.localizedDescription)"),
                id: nil
            )
            return
        }

        // Dispatch
        let uptime = Int(Date().timeIntervalSince(startTime))
        let response = dispatcher.dispatch(rawRequest, uptimeSeconds: uptime)

        // Check if this was a shutdown request
        let isShutdown = rawRequest.method == RPCMethod.shutdown

        // Send response
        sendJSONResponse(context: context, response: response)

        if isShutdown {
            shutdownCallback()
        }
    }

    private func handleStreamRequest(context: ChannelHandlerContext, bodyData: Data) {
        let params: GenerateParams
        do {
            params = try JSONDecoder().decode(GenerateParams.self, from: bodyData)
        } catch {
            sendErrorResponse(
                context: context,
                status: .badRequest,
                rpcError: JSONRPCError(code: -32602, message: "Invalid stream params: \(error.localizedDescription)"),
                id: nil
            )
            return
        }

        guard dispatcherIsModelLoaded else {
            sendErrorResponse(
                context: context,
                status: .badRequest,
                rpcError: .modelNotLoaded(),
                id: nil
            )
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-ndjson")
        headers.add(name: "Transfer-Encoding", value: "chunked")
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.flush()

        do {
            let result = try dispatcher.generateStreaming(
                params: params,
                onToken: { token in
                    self.sendStreamChunk(
                        context: context,
                        StreamChunk(delta: token, done: false, tokensUsed: nil, durationMs: nil, error: nil)
                    )
                }
            )
            sendStreamChunk(
                context: context,
                StreamChunk(
                    delta: "",
                    done: true,
                    tokensUsed: result.tokensUsed,
                    durationMs: result.durationMs,
                    error: nil
                )
            )
        } catch {
            sendStreamChunk(
                context: context,
                StreamChunk(delta: "", done: true, tokensUsed: nil, durationMs: nil, error: error.localizedDescription)
            )
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private var dispatcherIsModelLoaded: Bool {
        dispatcher.isModelLoaded
    }

    private func sendStreamChunk(context: ChannelHandlerContext, _ chunk: StreamChunk) {
        guard let data = try? JSONEncoder().encode(chunk),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count + 1)
        buffer.writeString(text)
        buffer.writeString("\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    private func sendJSONResponse(context: ChannelHandlerContext, response: JSONRPCResponseEnvelope) {
        let data: Data
        do {
            data = try JSONEncoder().encode(response)
        } catch {
            sendErrorResponse(
                context: context,
                status: .internalServerError,
                rpcError: .internalError,
                id: nil
            )
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var body = context.channel.allocator.buffer(capacity: data.count)
        body.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendErrorResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        rpcError: JSONRPCError,
        id: Int?
    ) {
        let response = JSONRPCResponseEnvelope.failure(rpcError, id: id)
        sendJSONResponse(context: context, response: response)
    }
}

private struct StreamChunk: Codable {
    let delta: String
    let done: Bool
    let tokensUsed: Int?
    let durationMs: Int?
    let error: String?
}
