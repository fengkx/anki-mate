import ArgumentParser
import DictKit
import DictKitSystemDictionary
import Foundation

public struct DictKitCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "dictkit",
        abstract: "Query and parse entries from the macOS system dictionary.",
        subcommands: [LookupCommand.self, DictKitSpeechCommand.self],
        defaultSubcommand: LookupCommand.self
    )

    public init() {}

    static func commandFailure(for error: LookupError) -> CommandFailure? {
        switch error {
        case .dictionaryUnavailable(let name):
            return CommandFailure(message: "Dictionary unavailable: \(name)")
        case .sourceUnavailable:
            return CommandFailure(message: "The private dictionary source is unavailable on this build.")
        case .parseFailed:
            return CommandFailure(message: "Dictionary content was fetched but could not be parsed.")
        case .notFound:
            return nil
        }
    }
}

struct CommandFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
