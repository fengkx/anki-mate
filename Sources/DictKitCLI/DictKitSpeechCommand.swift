import ArgumentParser
import DictKit
import DictKitSystemDictionary
import Foundation

protocol DictionarySpeechCommandClient: Sendable {
    func synthesizeSync(_ request: LookupSpeechRequest) throws -> SynthesizedSpeech
}

extension DictionarySpeechClient: DictionarySpeechCommandClient {}

enum SpeechCommandLookupSource: String, ExpressibleByArgument, CaseIterable {
    case automatic
    case `public`
    case html

    var dictionaryLookupSource: DictionaryLookupSource {
        switch self {
        case .automatic:
            return .automatic
        case .public:
            return .publicAPI
        case .html:
            return .privateHTML()
        }
    }
}

struct SpeechCommandOutput: Codable {
    let query: String
    let outputPath: String
    let contentType: String
    let fileExtension: String
    let pronunciationUsed: Pronunciation?
    let voiceIdentifier: String?
    let language: String?
    let didFallbackToText: Bool
    let warnings: [String]
}

public struct DictKitSpeechCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "speech",
        abstract: "Synthesize dictionary pronunciation audio and write it to a wav file."
    )

    static var makeClient: @Sendable (SpeechSynthesisConfiguration) -> any DictionarySpeechCommandClient = { configuration in
        DictionarySpeechClient(configuration: configuration)
    }

    @Option(name: .shortAndLong, help: "Output audio file path. Appends .wav when no extension is provided.")
    var output: String

    @Flag(help: "Print synthesis metadata as structured JSON.")
    var json = false

    @Option(help: "Prefer or require a specific dialect, such as AmE or BrE.")
    var dialect: String?

    @Option(help: "Zero-based lexical entry index to synthesize from.")
    var lexicalEntry: Int?

    @Option(help: "Lookup source: automatic, public, or html.")
    var source: SpeechCommandLookupSource = .automatic

    @Flag(help: "Fail when no dictionary pronunciation candidate is available.")
    var strict = false

    @Option(help: "Specific system voice identifier to use.")
    var voiceIdentifier: String?

    @Option(help: "Language hint such as en-US.")
    var languageHint: String?

    @Argument(help: "The word or phrase to synthesize.")
    var query: [String] = []

    public init() {}

    init(
        output: String,
        json: Bool,
        dialect: String?,
        lexicalEntry: Int?,
        source: SpeechCommandLookupSource,
        strict: Bool,
        voiceIdentifier: String?,
        languageHint: String?,
        query: [String]
    ) {
        self.output = output
        self.json = json
        self.dialect = dialect
        self.lexicalEntry = lexicalEntry
        self.source = source
        self.strict = strict
        self.voiceIdentifier = voiceIdentifier
        self.languageHint = languageHint
        self.query = query
    }

    public mutating func run() throws {
        let request = try makeLookupRequest()
        let outputURL = try resolvedOutputURL()

        var configuration = SpeechSynthesisConfiguration()
        if strict {
            configuration.fallbackPolicy = .failIfNoPronunciation
        }
        configuration.voiceIdentifier = voiceIdentifier
        configuration.languageHint = languageHint
        if let dialect {
            configuration.preferredDialectOrder = [dialect]
        }

        let client = Self.makeClient(configuration)
        let result: SynthesizedSpeech
        do {
            result = try client.synthesizeSync(request)
        } catch let error as SpeechError {
            throw Self.commandFailure(for: error) ?? error
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.audioData.write(to: outputURL)

        if json {
            let payload = SpeechCommandOutput(
                query: request.term,
                outputPath: outputURL.path,
                contentType: result.contentType,
                fileExtension: result.fileExtension,
                pronunciationUsed: result.pronunciationUsed,
                voiceIdentifier: result.voiceIdentifier,
                language: result.language,
                didFallbackToText: result.didFallbackToText,
                warnings: result.warnings
            )
            printEncodedJSON(payload)
        }
    }

    func makeLookupRequest() throws -> LookupSpeechRequest {
        let term = query.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            throw ValidationError("Please provide a word or phrase to synthesize.")
        }

        if let lexicalEntry, lexicalEntry < 0 {
            throw ValidationError("The lexical entry index must be zero or greater.")
        }

        let selection: PronunciationSelection
        if let lexicalEntry {
            selection = .lexicalEntry(index: lexicalEntry, dialect: dialect)
        } else if let dialect {
            selection = .exactDialect(dialect)
        } else {
            selection = .preferredDialectFirst
        }

        return LookupSpeechRequest(
            term: term,
            source: source.dictionaryLookupSource,
            selection: selection
        )
    }

    func resolvedOutputURL() throws -> URL {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError("Please provide an output path.")
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        if url.pathExtension.isEmpty {
            return url.appendingPathExtension("wav")
        }
        return url
    }

    static func commandFailure(for error: SpeechError) -> CommandFailure? {
        switch error {
        case .voiceNotFound(let identifier):
            return CommandFailure(message: "Voice not found: \(identifier)")
        case .noPronunciationCandidates:
            return CommandFailure(message: "No pronunciation candidate matched the requested selection.")
        case .audioEncodingFailed:
            return CommandFailure(message: "Speech audio was synthesized but could not be encoded as wav.")
        case .invalidRequest(let message):
            return CommandFailure(message: message)
        case .lookupFailed(let lookupError):
            return DictKitCommand.commandFailure(for: lookupError)
        case .synthesisUnavailable:
            return CommandFailure(message: "Speech synthesis is unavailable in the current environment.")
        }
    }
}

func printEncodedJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    do {
        let data = try encoder.encode(value)
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    } catch {
        fputs("JSON encoding failed: \(error)\n", stderr)
    }
}
