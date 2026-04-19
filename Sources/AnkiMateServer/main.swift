// AnkiMate local inference server — JSON-RPC 2.0 over HTTP.
//
// Usage: AnkiMateServer [port] [--parent-pid PID]
//   port: TCP port to bind (0 = auto-assign). Default: 0
//
// On startup, prints "LISTENING:<port>" to stdout so the parent process can discover the port.

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AnkiMateRPC

let launchConfiguration = try ServerLaunchConfiguration(arguments: CommandLine.arguments)
let port = launchConfiguration.port

let engine = InferenceEngine()
let dispatcher = RPCDispatcher(engine: engine)
let startTime = Date()

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
var serverChannel: Channel?
var parentProcessMonitor: ParentProcessMonitor?

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(.backlog, value: 8)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
            channel.pipeline.addHandler(
                HTTPHandler(dispatcher: dispatcher, startTime: startTime, shutdownCallback: {
                    guard let serverChannel else { return }
                    serverChannel.eventLoop.execute {
                        serverChannel.close(promise: nil)
                    }
                })
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

// Signal port to parent process
print("LISTENING:\(actualPort)")
fflush(stdout)

fputs("AnkiMateServer running on 127.0.0.1:\(actualPort)\n", stderr)

if let expectedParentProcessID = launchConfiguration.expectedParentProcessID {
    parentProcessMonitor = ParentProcessMonitor(expectedParentProcessID: expectedParentProcessID) {
        fputs("Parent process \(expectedParentProcessID) exited; shutting down AnkiMateServer\n", stderr)
        fflush(stderr)

        guard let serverChannel else {
            exit(EXIT_SUCCESS)
        }

        serverChannel.eventLoop.execute {
            serverChannel.close(promise: nil)
        }
    }
    parentProcessMonitor?.start()
}

try channel.closeFuture.wait()
parentProcessMonitor?.stop()
try group.syncShutdownGracefully()
