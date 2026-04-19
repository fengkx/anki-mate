import Foundation

enum ServerLaunchConfigurationError: Error, Equatable {
    case invalidArgument(String)
    case missingValue(String)
}

struct ServerLaunchConfiguration: Equatable {
    let port: Int
    let expectedParentProcessID: Int32?

    init(port: Int, expectedParentProcessID: Int32?) {
        self.port = port
        self.expectedParentProcessID = expectedParentProcessID
    }

    init(arguments: [String]) throws {
        self = try Self.parse(arguments: arguments)
    }

    static func parse(arguments: [String]) throws -> ServerLaunchConfiguration {
        var port = 0
        var expectedParentProcessID: Int32?
        var consumedPositionalPort = false
        let rawArguments = Array(arguments.dropFirst())
        var index = 0

        while index < rawArguments.count {
            let argument = rawArguments[index]

            if !consumedPositionalPort, let parsedPort = Int(argument) {
                port = parsedPort
                consumedPositionalPort = true
                index += 1
                continue
            }

            switch argument {
            case "--parent-pid":
                let valueIndex = index + 1
                guard valueIndex < rawArguments.count else {
                    throw ServerLaunchConfigurationError.missingValue(argument)
                }
                guard let pid = Int32(rawArguments[valueIndex]), pid > 0 else {
                    throw ServerLaunchConfigurationError.invalidArgument(argument)
                }
                expectedParentProcessID = pid
                index += 2

            default:
                throw ServerLaunchConfigurationError.invalidArgument(argument)
            }
        }

        return ServerLaunchConfiguration(
            port: port,
            expectedParentProcessID: expectedParentProcessID
        )
    }
}
