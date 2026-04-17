import XCTest

final class CLISmokeTests: XCTestCase {

    // MARK: - Existing tests

    func testCLIPrintsStructuredJSON() throws {
        try SystemDictionaryTestSupport.requirePublicLookup(for: "apple")
        let result = try run("--json", "apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"query\" : \"apple\""))
        XCTAssertTrue(result.stdout.contains("\"usedSource\""))
    }

    func testCLIHelpIncludesSpeechSubcommand() throws {
        let result = try run("--help")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("speech"))
    }

    // MARK: - Default human-readable lookup

    func testCLIDefaultHumanReadableLookup() throws {
        try SystemDictionaryTestSupport.requirePublicLookup(for: "apple")
        let result = try run("apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertFalse(result.stdout.contains("No entry found"), result.stdout)
        XCTAssertTrue(result.stdout.contains("apple"), "Expected headword 'apple' in output")
    }

    // MARK: - HTML-JSON lookup

    func testCLIHtmlJsonLookup() throws {
        try SystemDictionaryTestSupport.requirePrivateHTMLLookup(for: "apple")
        let result = try run("--html-json", "apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"query\""), "Expected JSON key 'query' in html-json output")
        // Verify output is valid JSON
        let data = Data(result.stdout.utf8)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), "Output should be valid JSON")
    }

    // MARK: - Raw HTML lookup

    func testCLIRawHtmlLookup() throws {
        try SystemDictionaryTestSupport.requirePrivateHTMLLookup(for: "apple")
        let result = try run("--raw-html", "apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("<"), "Expected HTML tags in raw-html output")
    }

    // MARK: - List dictionaries

    func testCLIListDicts() throws {
        let result = try run("--list-dicts")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "Expected at least one dictionary listed")
    }

    // MARK: - Not-found word exits zero

    func testCLINotFoundExitsZero() throws {
        let result = try run("--json", "xyznonexistentword123")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("No entry found"), "Expected not-found message")
    }

    // MARK: - Speech subcommand help

    func testCLISpeechHelp() throws {
        let result = try run("speech", "--help")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("--output"), "Expected --output option in speech help")
    }

    // MARK: - Missing query shows error

    func testCLIMissingQueryShowsError() throws {
        let result = try run("--json")

        XCTAssertNotEqual(result.exitCode, 0, "Expected non-zero exit for missing query")
        XCTAssertFalse(result.stderr.isEmpty, "Expected error message on stderr")
    }

    // MARK: - Speech synthesis end-to-end

    func testCLISpeechWritesValidWavFile() throws {
        try SystemDictionaryTestSupport.requireAutomaticLookup(for: "apple")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("apple.wav").path
        let result = try run("speech", "--output", outputPath, "apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        XCTAssertGreaterThan(data.count, 44, "WAV file should be larger than just a header")
        // RIFF header check
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF", "File should start with RIFF header")
    }

    func testCLISpeechJsonOutputIncludesMetadata() throws {
        try SystemDictionaryTestSupport.requireAutomaticLookup(for: "apple")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("apple").path
        let result = try run("speech", "--json", "--output", outputPath, "apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("\"query\" : \"apple\""))
        XCTAssertTrue(result.stdout.contains("\"contentType\" : \"audio/wav\""))
        // --output without extension should get .wav appended
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath + ".wav"),
                      "Expected .wav extension to be appended")
    }

    func testCLISpeechProducesPronunciationNotSpelling() throws {
        try SystemDictionaryTestSupport.requireAutomaticLookup(for: "apple")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("apple.wav").path
        let result = try run("speech", "--output", outputPath, "apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        // A word pronounced correctly is ~0.5-1s at 16kHz (8000-16000 frames, 32000-64000 bytes of f32).
        // Spelled out letter-by-letter would be ~3s+ (>96000 bytes).
        // Use a generous upper bound to catch spelling-out regression.
        XCTAssertLessThan(data.count, 96000,
                          "Audio too long (\(data.count) bytes) — likely spelling out letters instead of pronouncing the word")
    }

    func testCLISpeechMissingOutputShowsError() throws {
        let result = try run("speech", "apple")

        XCTAssertNotEqual(result.exitCode, 0, "Expected non-zero exit when --output is missing")
        XCTAssertFalse(result.stderr.isEmpty, "Expected error message on stderr")
    }

    func testCLISpeechStrictFailsForNonexistentWord() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("out.wav").path
        let result = try run("speech", "--strict", "--output", outputPath, "xyznonexistentword123")

        XCTAssertNotEqual(result.exitCode, 0, "Expected non-zero exit for nonexistent word in strict mode")
    }

    func testCLISpeechWithSourceOption() throws {
        try SystemDictionaryTestSupport.requireAutomaticLookup(for: "apple")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("apple.wav").path
        let result = try run("speech", "--source", "automatic", "--output", outputPath, "apple")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        XCTAssertGreaterThan(data.count, 44, "WAV file should be larger than just a header")
    }

    func testCLISpeechMissingQueryShowsError() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("out.wav").path
        let result = try run("speech", "--output", outputPath)

        XCTAssertNotEqual(result.exitCode, 0, "Expected non-zero exit when query is missing")
    }

    // MARK: - Speech IPA mode vs plain text mode

    func testCLISpeechDefaultUsesPlainText() throws {
        try SystemDictionaryTestSupport.requireAutomaticLookup(for: "artifact")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("artifact.wav").path
        let result = try run("speech", "--json", "--output", outputPath, "artifact")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        // Default mode should not use IPA — pronunciationUsed should be null
        XCTAssertTrue(result.stdout.contains("\"pronunciationUsed\" : null") ||
                      !result.stdout.contains("\"ipa\""),
                      "Default mode should not pass IPA to synthesizer")
    }

    func testCLISpeechIPAFlagUsesRealIPA() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "System dictionary IPA data varies on CI runners")
        try SystemDictionaryTestSupport.requireAutomaticLookup(for: "dictionary")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("dictionary.wav").path
        let result = try run("speech", "--ipa", "--json", "--output", outputPath, "dictionary")

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        // --ipa mode should use real IPA, not respelling
        XCTAssertTrue(result.stdout.contains("\"didFallbackToText\" : false"),
                      "Should use IPA pronunciation, not fall back to text")
        XCTAssertFalse(result.stdout.contains("SH"),
                       "Output contains respelling digraph SH — expected real IPA")
    }

    // MARK: - Multi-word lookup coverage

    func testCLIJsonLookupMultipleWords() throws {
        let words = ["hello", "run", "elaborate", "beautiful", "dictionary"]
        try SystemDictionaryTestSupport.requirePublicLookups(for: words)
        for word in words {
            let result = try run("--json", word)
            XCTAssertEqual(result.exitCode, 0, "Failed for '\(word)': \(result.stderr)")
            XCTAssertTrue(result.stdout.contains("\"query\" : \"\(word)\""),
                          "Missing query key for '\(word)'")
        }
    }

    func testCLIHumanReadableLookupMultipleWords() throws {
        let words = ["world", "computer", "language", "swift"]
        try SystemDictionaryTestSupport.requirePublicLookups(for: words)
        for word in words {
            let result = try run(word)
            XCTAssertEqual(result.exitCode, 0, "Failed for '\(word)': \(result.stderr)")
            XCTAssertFalse(result.stdout.contains("No entry found"), "Lookup unexpectedly failed for '\(word)': \(result.stdout)")
            XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Empty output for '\(word)'")
        }
    }

    // MARK: - Multi-word speech coverage

    func testCLISpeechMultipleWords() throws {
        let words = ["hello", "run", "elaborate", "beautiful", "dictionary"]
        try SystemDictionaryTestSupport.requireAutomaticLookups(for: words)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for word in words {
            let outputPath = tempDir.appendingPathComponent("\(word).wav").path
            let result = try run("speech", "--output", outputPath, word)

            XCTAssertEqual(result.exitCode, 0, "Speech failed for '\(word)': \(result.stderr)")
            let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            XCTAssertGreaterThan(data.count, 44, "WAV too small for '\(word)'")
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF",
                           "Invalid WAV header for '\(word)'")
        }
    }

    func testCLISpeechMultipleWordsNotSpelledOut() throws {
        let words = ["hello", "elaborate", "beautiful", "dictionary"]
        try SystemDictionaryTestSupport.requireAutomaticLookups(for: words)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for word in words {
            let outputPath = tempDir.appendingPathComponent("\(word).wav").path
            let result = try run("speech", "--output", outputPath, word)

            XCTAssertEqual(result.exitCode, 0, "Speech failed for '\(word)': \(result.stderr)")
            let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            // Spoken audio varies by word length and voice, but spelled-out audio is
            // dramatically larger (each letter becomes a separate utterance).
            // Use a generous per-character budget to avoid false positives.
            let maxBytes = word.count * 50000
            XCTAssertLessThan(data.count, maxBytes,
                              "Audio for '\(word)' too long (\(data.count) bytes) — likely spelling out letters")
        }
    }

    // MARK: - Helpers

    private func run(_ arguments: String...) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("dictkit")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return (stdout, stderr, process.terminationStatus)
    }

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Unable to locate products directory")
    }
}
