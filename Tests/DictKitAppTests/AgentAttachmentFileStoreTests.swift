import AppKit
import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import DictKitApp

final class AgentAttachmentFileStoreTests: XCTestCase {
    func testImportPastedImageWritesManagedAttachmentFile() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AgentAttachmentFileStore(rootURL: rootURL)
        let sessionID = UUID()
        let imageData = try XCTUnwrap(Self.onePixelPNGData())

        let attachment = try store.importPastedImage(
            imageData,
            sessionID: sessionID,
            existingCount: 0
        )

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.fileName, "pasted-image.png")
        XCTAssertEqual(try store.data(for: attachment), imageData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: attachment).path))
    }

    func testPasteboardImageReaderExtractsPNGData() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agent-attachment-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let imageData = try XCTUnwrap(Self.onePixelPNGData())
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))

        XCTAssertEqual(AgentComposerPasteboardImageReader.pngData(from: pasteboard), imageData)
    }

    func testPasteboardImageReaderExtractsImageFileURL() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("agent-attachment-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let imageData = try XCTUnwrap(Self.onePixelPNGData())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try imageData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        XCTAssertNotNil(AgentComposerPasteboardImageReader.pngData(from: pasteboard))
    }

    private static func onePixelPNGData() -> Data? {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")
    }
}
