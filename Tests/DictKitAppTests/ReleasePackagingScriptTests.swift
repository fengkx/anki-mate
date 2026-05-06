import XCTest

final class ReleasePackagingScriptTests: XCTestCase {
    func testPackageScriptExportsDidNotarizeBeforeWritingManifest() throws {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let scriptURL = repositoryRoot.appendingPathComponent("scripts/package-macos-release.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let exportRange = try XCTUnwrap(
            script.range(of: "export DID_NOTARIZE"),
            "package-macos-release.sh must export DID_NOTARIZE for the manifest writer subprocess"
        )
        let writeManifestRange = try XCTUnwrap(
            script.range(of: "\nwrite_release_manifest\n", options: .backwards),
            "package-macos-release.sh should call write_release_manifest"
        )

        XCTAssertLessThan(
            exportRange.lowerBound,
            writeManifestRange.lowerBound,
            "DID_NOTARIZE must be exported before write_release_manifest runs"
        )
    }
}
