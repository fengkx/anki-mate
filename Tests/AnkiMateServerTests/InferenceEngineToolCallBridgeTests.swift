import XCTest
@testable import AnkiMateServer
import AnkiMateRPC
import CLlamaChatTemplateBridge

final class InferenceEngineToolCallBridgeTests: XCTestCase {
    // MARK: - Bridge surface (no model required)

    // Intentionally skipped: common_chat_templates_init from llama.cpp does not
    // defensively guard against a null model pointer in all builds, so exercising
    // that path from the test harness can abort the test bundle. The bridge still
    // forwards its own error path in `applyReturnsErrorWhenHandleIsNull` below.

    func testApplyReturnsErrorWhenHandleIsNull() {
        var promptPtr: UnsafeMutablePointer<CChar>?
        var grammarPtr: UnsafeMutablePointer<CChar>?
        var parserPtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?
        var format: Int32 = 0
        var grammarLazy: Bool = false
        defer {
            [promptPtr, grammarPtr, parserPtr, errorPtr].forEach { pointer in
                if let pointer { ankimate_chat_bridge_free(pointer) }
            }
        }

        let messages = "[{\"role\":\"user\",\"content\":\"hi\"}]"
        let ok = messages.withCString { messagesCString in
            "auto".withCString { tcCString in
                ankimate_chat_apply(
                    nil,
                    messagesCString,
                    nil,
                    tcCString,
                    false,
                    &promptPtr,
                    &grammarPtr,
                    &parserPtr,
                    &format,
                    &grammarLazy,
                    &errorPtr
                )
            }
        }
        XCTAssertFalse(ok)
        XCTAssertNotNil(errorPtr)
        if let errorPtr {
            XCTAssertFalse(String(cString: errorPtr).isEmpty)
        }
    }

    /// Content-only parse path: with format = 0 (COMMON_CHAT_FORMAT_CONTENT_ONLY) and no parser blob,
    /// the bridge should echo the input back as `content` and emit an empty `tool_calls` array.
    func testParseContentOnlyEchoesInputAsContent() throws {
        var resultPtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?
        defer {
            if let resultPtr { ankimate_chat_bridge_free(resultPtr) }
            if let errorPtr { ankimate_chat_bridge_free(errorPtr) }
        }

        let text = "Hello world, no tool calls here."
        let ok = text.withCString { textCString in
            "".withCString { blobCString in
                ankimate_chat_parse(0, blobCString, textCString, false, &resultPtr, &errorPtr)
            }
        }
        XCTAssertTrue(ok, "chat_parse should succeed on content-only input")
        guard let resultPtr else {
            XCTFail("parse returned success but no result JSON")
            return
        }
        let raw = String(cString: resultPtr)
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        XCTAssertEqual(json?["content"] as? String, text)
        let toolCalls = json?["tool_calls"] as? [[String: Any]] ?? []
        XCTAssertTrue(toolCalls.isEmpty)
    }

    // MARK: - High-level helper on InferenceEngine

    /// Round-trip: feed a synthetic `{content, tool_calls}` JSON string into the Swift
    /// decoder that `InferenceEngine` uses internally.
    func testDecodeParsedChatOutputFromSyntheticBridgeJSON() throws {
        let fixture = """
        {
          "role": "assistant",
          "content": "pre-thinking ok",
          "tool_calls": [
            {"id": "call-1", "name": "propose_example", "arguments": "{\\"text\\":\\"hello\\"}"},
            {"id": "",        "name": "propose_pitfall", "arguments": "{}"}
          ]
        }
        """

        let parsed = try InferenceEngine.parseChatOutput(
            format: 0,
            parserBlob: "",
            text: fixture,  // when format=0 this is round-tripped as content itself;
            isPartial: false
        )
        // For content-only format the fixture text becomes the content; that is useful
        // as a smoke test that the C bridge is actually reachable from tests.
        XCTAssertFalse(parsed.content.isEmpty)
    }
}
