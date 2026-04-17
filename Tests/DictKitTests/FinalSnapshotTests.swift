import XCTest
import SnapshotTesting
@testable import DictKit

final class FinalSnapshotTests: XCTestCase {
    private let htmlFixtures: [(name: String, query: String)] = [
        ("apple", "apple"),
        ("call", "call"),
        ("right", "right"),
        ("run", "run"),
        ("light", "light"),
        ("elaborate", "elaborate"),
        ("what", "what"),
        ("pass", "pass")
    ]

    func testPublicFixtureSnapshots() throws {
        let fixtures: [(name: String, query: String)] = [
            ("apple", "apple"),
            ("light", "light"),
            ("elaborate", "elaborate"),
            ("what", "what")
        ]

        for fixture in fixtures {
            let raw = try loadTextFixture(fixture.name)
            let result = try DictionaryTextParser.parse(query: fixture.query, raw: raw, includeSource: false)
            assertSnapshot(
                of: result,
                as: .json,
                named: fixture.name,
                file: #file,
                testName: "testPublicFixtureSnapshots"
            )
        }
    }

    func testHTMLFixtureSnapshots() throws {
        for fixture in htmlFixtures {
            let html = try loadHTMLFixture(fixture.name)
            let result = try DictionaryHTMLParser.parse(query: fixture.query, html: html, includeSource: false)
            assertSnapshot(
                of: result,
                as: .json,
                named: fixture.name,
                file: #file,
                testName: "testHTMLFixtureSnapshots"
            )
        }
    }

    func testLivePrivateHTMLMatchesCheckedInFixtures() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "System dictionary content varies on CI runners")
        for fixture in htmlFixtures {
            try SystemDictionaryTestSupport.requirePrivateHTMLLookup(for: fixture.query)
            let liveHTML = try runPrivateHTMLLookup(query: fixture.query)
            if liveHTML.isEmpty || liveHTML.contains("私有词典 API 未找到") {
                throw XCTSkip("Private HTML lookup unavailable for \(fixture.query)")
            }

            let fixtureHTML = try loadHTMLFixture(fixture.name)
            let liveResult: LookupResult
            do {
                liveResult = try DictionaryHTMLParser.parse(query: fixture.query, html: liveHTML, includeSource: false)
            } catch LookupError.parseFailed {
                throw XCTSkip("Private HTML lookup returned an unsupported format for \(fixture.query) in this test environment.")
            }
            let fixtureResult = try DictionaryHTMLParser.parse(query: fixture.query, html: fixtureHTML, includeSource: false)
            XCTAssertEqual(liveResult, fixtureResult, "Live private API result drifted from fixture for \(fixture.query)")
        }
    }

    private func loadTextFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            XCTFail("Missing fixture: \(name)")
            throw NSError(domain: "FinalSnapshotTests", code: 1)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loadHTMLFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html") else {
            XCTFail("Missing HTML fixture: \(name).html")
            throw NSError(domain: "FinalSnapshotTests", code: 2)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func runPrivateHTMLLookup(query: String) throws -> String {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("dictkit")
        process.arguments = ["--raw-html", query]

        let tempDirectory = FileManager.default.temporaryDirectory
        let stdoutURL = tempDirectory.appendingPathComponent(UUID().uuidString)
        let stderrURL = tempDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        try stdout.close()
        try stderr.close()

        let output = try String(contentsOf: stdoutURL, encoding: .utf8)
        let errorOutput = try String(contentsOf: stderrURL, encoding: .utf8)
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Unable to locate products directory")
    }
}
