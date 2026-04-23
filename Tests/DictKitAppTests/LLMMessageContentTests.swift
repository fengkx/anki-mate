import Foundation
import XCTest
@testable import AnkiMateRPC

final class LLMMessageContentTests: XCTestCase {
    func testChatMessageEncodesPlainTextContentAsString() throws {
        let message = ChatMessage(role: "user", content: .text("Hello"))
        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains(#""content":"Hello""#))
    }

    func testChatMessageEncodesMultimodalContentAsOpenAIStyleParts() throws {
        let message = ChatMessage(
            role: "user",
            content: .parts([
                .text("What is in this image?"),
                .imageURL("data:image/png;base64,abc123"),
            ])
        )

        let data = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains(#""type":"text""#))
        XCTAssertTrue(json.contains(#""text":"What is in this image?""#))
        XCTAssertTrue(json.contains(#""type":"image_url""#))
        XCTAssertTrue(json.contains(#""url":"data:image\/png;base64,abc123""#))
    }

    func testModelInfoDefaultsVisionSupportToFalseWhenFieldIsMissing() throws {
        let data = Data(
            """
            {
              "id": "text-model",
              "displayName": "Text Model",
              "fileName": "text.gguf",
              "url": "https://example.com/text.gguf",
              "sizeBytes": 1,
              "quantization": "Q4",
              "contextSize": 4096,
              "recommended": true
            }
            """.utf8
        )

        let model = try JSONDecoder().decode(ModelInfo.self, from: data)

        XCTAssertFalse(model.supportsVision)
        XCTAssertNil(model.mmprojFileName)
    }

    func testModelInfoDecodesVisionProjectorMetadata() throws {
        let data = Data(
            """
            {
              "id": "vision-model",
              "displayName": "Vision Model",
              "fileName": "model.gguf",
              "url": "https://example.com/model.gguf",
              "sizeBytes": 10,
              "quantization": "Q4",
              "contextSize": 4096,
              "recommended": true,
              "supportsVision": true,
              "mmprojFileName": "mmproj-F16.gguf",
              "mmprojURL": "https://example.com/mmproj-F16.gguf",
              "mmprojSizeBytes": 5
            }
            """.utf8
        )

        let model = try JSONDecoder().decode(ModelInfo.self, from: data)

        XCTAssertTrue(model.requiresMMProj)
        XCTAssertEqual(model.totalSizeBytes, 15)
        XCTAssertEqual(model.mmprojFileName, "mmproj-F16.gguf")
    }
}
