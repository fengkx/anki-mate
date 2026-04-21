// HTTP handler for the AnkiMateServer.
//
// Routes:
//   POST /  — JSON-RPC 2.0 (control plane: health, loadModel, unloadModel, shutdown)
//
// Data-plane requests (chat completions) go directly to the llama-server child port,
// discovered via the `inferencePort` field in the health RPC response.

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

    init(
        dispatcher: RPCDispatcher,
        startTime: Date,
        shutdownCallback: @escaping () -> Void
    ) {
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

        guard head.method == .POST, head.uri == "/" else {
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

        let isShutdown = rawRequest.method == RPCMethod.shutdown
        let uptime = Int(Date().timeIntervalSince(startTime))

        Task {
            let response = await self.dispatcher.dispatch(rawRequest, uptimeSeconds: uptime)
            context.eventLoop.execute {
                guard context.channel.isActive else { return }
                self.sendJSONResponse(context: context, response: response)
                if isShutdown {
                    self.shutdownCallback()
                }
            }
        }
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
