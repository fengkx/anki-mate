// AnkiMate local inference server — supervisor for llama-server.
//
// Usage: AnkiMateServer [port] [--parent-pid PID]
//   port: TCP port to bind (0 = auto-assign). Default: 0
//
// On startup, prints "LISTENING:<port>" to stdout so the parent process can discover the port.
//
// Control plane: JSON-RPC 2.0 over POST / (health, loadModel, unloadModel, shutdown)
// Data plane: Clients talk directly to llama-server child port (returned in health response)

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AnkiMateRPC

let launchConfiguration = try ServerLaunchConfiguration(arguments: CommandLine.arguments)
let port = launchConfiguration.port
let startTime = Date()

// Late-bind supervisor after we know the actual port.
final class ServerContext {
    var dispatcher: RPCDispatcher?
    var startTime: Date
    var shutdownCallback: (() -> Void)?

    init(startTime: Date) {
        self.startTime = startTime
    }
}

let serverContext = ServerContext(startTime: startTime)

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
var serverChannel: Channel?
var parentProcessMonitor: ParentProcessMonitor?
var signalShutdownCoordinator: ServerSignalShutdownCoordinator?

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(.backlog, value: 8)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(
                DeferredHTTPHandler(context: serverContext)
            )
        }
    }
    .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

let channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
serverChannel = channel
guard let localAddress = channel.localAddress, let actualPort = localAddress.port else {
    fputs("error: could not determine bound port\n", stderr)
    exit(1)
}

let childPort = actualPort + 1
LlamaServerChildRegistry().reapStaleChildren()
let supervisor = LlamaServerSupervisor(childPort: childPort)
let dispatcher = RPCDispatcher(supervisor: supervisor)

@Sendable func requestShutdown() {
    Task {
        await supervisor.shutdown()

        guard let serverChannel else {
            exit(EXIT_SUCCESS)
        }

        serverChannel.eventLoop.execute {
            serverChannel.close(promise: nil)
        }
    }
}

serverContext.dispatcher = dispatcher
serverContext.shutdownCallback = {
    guard let serverChannel else { return }
    serverChannel.eventLoop.execute {
        serverChannel.close(promise: nil)
    }
}

signalShutdownCoordinator = ServerSignalShutdownCoordinator(shutdown: requestShutdown)
signalShutdownCoordinator?.start()

// Signal port to parent process
print("LISTENING:\(actualPort)")
fflush(stdout)

fputs("AnkiMateServer running on 127.0.0.1:\(actualPort) (llama-server child port: \(childPort))\n", stderr)

if let expectedParentProcessID = launchConfiguration.expectedParentProcessID {
    parentProcessMonitor = ParentProcessMonitor(expectedParentProcessID: expectedParentProcessID) {
        fputs("Parent process \(expectedParentProcessID) exited; shutting down AnkiMateServer\n", stderr)
        fflush(stderr)

        requestShutdown()
    }
    parentProcessMonitor?.start()
}

try channel.closeFuture.wait()
parentProcessMonitor?.stop()
signalShutdownCoordinator?.stop()

// Best-effort child cleanup on exit
let sema = DispatchSemaphore(value: 0)
Task {
    await supervisor.shutdown()
    sema.signal()
}
_ = sema.wait(timeout: .now() + 5)

try group.syncShutdownGracefully()

// MARK: - Deferred HTTP Handler

/// Thin NIO handler that delegates to HTTPHandler once the server context is initialized.
final class DeferredHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let serverContext: ServerContext
    private var inner: HTTPHandler?

    init(context: ServerContext) {
        self.serverContext = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if inner == nil, let dispatcher = serverContext.dispatcher {
            inner = HTTPHandler(
                dispatcher: dispatcher,
                startTime: serverContext.startTime,
                shutdownCallback: serverContext.shutdownCallback ?? {}
            )
        }

        guard let inner else {
            let response = HTTPResponseHead(version: .http1_1, status: .serviceUnavailable)
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }

        inner.channelRead(context: context, data: data)
    }
}
