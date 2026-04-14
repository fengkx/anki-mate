import XCTest

final class CLISmokeTests: XCTestCase {
    func testCLIPrintsStructuredJSON() throws {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent("dictkit")
        process.arguments = ["--json", "apple"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)
        XCTAssertTrue(output.contains("\"query\" : \"apple\""))
        XCTAssertTrue(output.contains("\"usedSource\""))
    }

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Unable to locate products directory")
    }
}
