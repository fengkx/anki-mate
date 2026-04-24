import XCTest
@testable import AnkiMateLLM
@testable import DictKitApp

final class AgentChatViewTests: XCTestCase {
    func testSanitizeKeepsAllAttachmentsWhenImagesAreSupported() {
        let image = AgentAttachment(
            kind: .image,
            mimeType: "image/png",
            fileName: "note.png",
            relativePath: "session/note.png",
            byteSize: 12
        )
        let text = AgentAttachment(
            kind: .textFile,
            mimeType: "text/plain",
            fileName: "note.txt",
            relativePath: "session/note.txt",
            byteSize: 8
        )

        let result = AgentDraftAttachmentCapabilities.sanitize([image, text], canAttachImages: true)

        XCTAssertEqual(result.kept, [image, text])
        XCTAssertTrue(result.removed.isEmpty)
    }

    func testSanitizeRemovesOnlyImageAttachmentsWhenImagesAreUnsupported() {
        let image = AgentAttachment(
            kind: .image,
            mimeType: "image/png",
            fileName: "note.png",
            relativePath: "session/note.png",
            byteSize: 12
        )
        let text = AgentAttachment(
            kind: .textFile,
            mimeType: "text/plain",
            fileName: "note.txt",
            relativePath: "session/note.txt",
            byteSize: 8
        )

        let result = AgentDraftAttachmentCapabilities.sanitize([image, text], canAttachImages: false)

        XCTAssertEqual(result.kept, [text])
        XCTAssertEqual(result.removed, [image])
    }
}
