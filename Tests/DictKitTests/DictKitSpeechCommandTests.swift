import Foundation
import XCTest
@testable import DictKit
@testable import DictKitCLI
@testable import DictKitSystemDictionary

final class DictKitSpeechCommandTests: XCTestCase {
    override func tearDown() {
        DictKitSpeechCommand.makeClient = { configuration in
            DictionarySpeechClient(configuration: configuration)
        }
        super.tearDown()
    }

    func testSpeechCommandWritesWaveFileAndUsesLexicalSelection() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let outputURL = tempDirectory.appendingPathComponent("anki-audio")

        let fakeClient = FakeDictionarySpeechCommandClient()
        DictKitSpeechCommand.makeClient = { configuration in
            fakeClient.configuration = configuration
            return fakeClient
        }

        var command = DictKitSpeechCommand(
            output: outputURL.path,
            json: false,
            dialect: "AmE",
            lexicalEntry: 1,
            source: .automatic,
            ipa: false,
            strict: false,
            voiceIdentifier: "voice.custom",
            languageHint: "en-US",
            query: ["elaborate"]
        )

        try command.run()

        let writtenURL = outputURL.appendingPathExtension("wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenURL.path))
        XCTAssertEqual(try Data(contentsOf: writtenURL), Data("wave".utf8))
        XCTAssertEqual(fakeClient.lastRequest?.term, "elaborate")
        XCTAssertEqual(fakeClient.lastRequest?.source, .automatic)
        XCTAssertEqual(fakeClient.configuration?.voiceIdentifier, "voice.custom")
        XCTAssertEqual(fakeClient.configuration?.languageHint, "en-US")

        guard case let .lexicalEntry(index, dialect)? = fakeClient.lastRequest?.selection else {
            return XCTFail("Expected lexical entry selection.")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(dialect, "AmE")
    }

    func testSpeechCommandUsesExactDialectSelectionWhenOnlyDialectProvided() throws {
        let command = DictKitSpeechCommand(
            output: "/tmp/example",
            json: false,
            dialect: "BrE",
            lexicalEntry: nil,
            source: .automatic,
            ipa: false,
            strict: false,
            voiceIdentifier: nil,
            languageHint: nil,
            query: ["what"]
        )

        let request = try command.makeLookupRequest()
        XCTAssertEqual(request.term, "what")
        XCTAssertEqual(request.source, .automatic)
        XCTAssertEqual(request.selection, .exactDialect("BrE"))
    }

    func testSpeechCommandMapsVoiceNotFoundToReadableFailure() {
        XCTAssertEqual(
            DictKitSpeechCommand.commandFailure(for: .voiceNotFound("voice.missing"))?.errorDescription,
            "Voice not found: voice.missing"
        )
    }
}

private final class FakeDictionarySpeechCommandClient: DictionarySpeechCommandClient, @unchecked Sendable {
    var lastRequest: LookupSpeechRequest?
    var configuration: SpeechSynthesisConfiguration?

    func synthesizeSync(_ request: LookupSpeechRequest) throws -> SynthesizedSpeech {
        lastRequest = request
        return SynthesizedSpeech(
            audioData: Data("wave".utf8),
            textSpoken: request.term,
            pronunciationUsed: Pronunciation(dialect: "AmE", ipa: "əˈlæbəˌreɪt", respelling: nil),
            voiceIdentifier: "voice.custom",
            language: "en-US",
            didFallbackToText: false,
            warnings: []
        )
    }
}
