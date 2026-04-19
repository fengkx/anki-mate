import Foundation
import XCTest
import AnkiMateRPC
@testable import DictKitApp
@testable import AnkiMateLLM

@MainActor
final class LLMServerDiagnosticsTests: XCTestCase {
    func testReportIncludesFailureAndBinaryPresence() {
        let report = LLMServerDiagnostics.makeReport(
            snapshot: .init(
                appVersion: "unknown",
                serverState: .failed("Server binary not found"),
                selectedModelId: "diagnostics-alpha",
                hasDownloadedSelectedModel: false,
                downloadedModelCount: 0,
                bundleServerBinaryDescription: "not available",
                developmentServerBinaryDescription: ".build/debug/AnkiMateServer [missing]",
                releaseServerBinaryDescription: ".build/release/AnkiMateServer [missing]",
                workingDirectory: "/tmp/anki-mate-tests"
            )
        )

        XCTAssertTrue(report.contains("Anki Mate Local AI Diagnostics"))
        XCTAssertTrue(report.contains("Server state: failed (Server binary not found)"))
        XCTAssertTrue(report.contains("Selected model: diagnostics-alpha"))
        XCTAssertTrue(report.contains("Development server binary: .build/debug/AnkiMateServer [missing]"))
    }
}
