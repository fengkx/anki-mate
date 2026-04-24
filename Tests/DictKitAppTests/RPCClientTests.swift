import Foundation
import XCTest
import AppKit
@testable import AnkiMateLLM
@testable import AnkiMateRPC
@testable import DictKitApp

final class RPCClientTests: XCTestCase {
    func testMergeStreamToolCallsCoalescesFragmentsByIndex() {
        let merged = RPCClient.mergeStreamToolCalls(
            [],
            with: [
                ChatToolCall(
                    index: 0,
                    id: "call_1",
                    function: ChatToolCallFunction(name: "read_card_", arguments: "{\"section\":")
                )
            ]
        )

        let completed = RPCClient.mergeStreamToolCalls(
            merged,
            with: [
                ChatToolCall(
                    index: 0,
                    function: ChatToolCallFunction(name: "snapshot", arguments: "\"front\"}")
                )
            ]
        )

        XCTAssertEqual(
            completed,
            [
                ChatToolCall(
                    index: 0,
                    id: "call_1",
                    function: ChatToolCallFunction(name: "read_card_snapshot", arguments: "{\"section\":\"front\"}")
                )
            ]
        )
    }

    func testStreamToolCallFunctionDecodingAllowsPartialFragments() throws {
        let data = Data(
            """
            {
              "index": 0,
              "function": {
                "arguments": "{\\"foo\\":"
              }
            }
            """.utf8
        )

        let fragment = try JSONDecoder().decode(ChatToolCall.self, from: data)

        XCTAssertEqual(fragment.index, 0)
        XCTAssertEqual(fragment.function.name, "")
        XCTAssertEqual(fragment.function.arguments, "{\"foo\":")
    }

    func testThinkingTaggedContentSplitsReasoningFromVisibleText() {
        let split = RPCClient.splitThinkingTaggedContent(
            "<think>step 1\nstep 2</think>\nFinal answer"
        )

        XCTAssertEqual(split.reasoning, "step 1\nstep 2")
        XCTAssertEqual(split.visible.trimmingCharacters(in: .whitespacesAndNewlines), "Final answer")
    }

    func testThinkingTaggedContentTreatsOpenThinkBlockAsReasoning() {
        let split = RPCClient.splitThinkingTaggedContent(
            "prefix<think>draft reasoning"
        )

        XCTAssertEqual(split.visible, "prefix")
        XCTAssertEqual(split.reasoning, "draft reasoning")
    }

    func testThinkingTaggedContentBuffersPartialStartTag() {
        let split = RPCClient.splitThinkingTaggedContent("visible <thi")

        XCTAssertEqual(split.visible, "visible ")
        XCTAssertEqual(split.reasoning, "")
    }

    func testThinkingTaggedContentBuffersPartialEndTagInsideReasoning() {
        let split = RPCClient.splitThinkingTaggedContent("<think>draft</thi")

        XCTAssertEqual(split.visible, "")
        XCTAssertEqual(split.reasoning, "draft")
    }
}

final class AgentComposerInputTests: XCTestCase {
    func testComposerTextViewAcceptsFirstResponder() {
        let textView = AgentComposerTextView()
        XCTAssertTrue(textView.acceptsFirstResponder)
    }

    func testPlaceholderUsesTextViewInsertionInsets() {
        XCTAssertEqual(AgentComposerLayout.placeholderHorizontalPadding, AgentComposerLayout.textContainerInset.width)
        XCTAssertEqual(AgentComposerLayout.placeholderVerticalPadding, AgentComposerLayout.textContainerInset.height)
    }

    func testPlaceholderStaysHiddenWhileInputMethodHasMarkedText() {
        XCTAssertFalse(
            AgentComposerPlaceholderVisibility.shouldShow(
                text: "",
                hasMarkedText: true
            )
        )
    }

    func testPlaceholderShowsOnlyWhenComposerIsActuallyEmpty() {
        XCTAssertTrue(
            AgentComposerPlaceholderVisibility.shouldShow(
                text: "",
                hasMarkedText: false
            )
        )
        XCTAssertFalse(
            AgentComposerPlaceholderVisibility.shouldShow(
                text: "hello",
                hasMarkedText: false
            )
        )
    }

    func testTextSyncDefersBoundTextWriteWhileInputMethodHasMarkedText() {
        XCTAssertFalse(
            AgentComposerTextSync.shouldApplyBoundText(
                currentText: "x",
                boundText: "",
                hasMarkedText: true
            )
        )
    }

    func testTextSyncAppliesBoundTextWriteOutsideInputMethodComposition() {
        XCTAssertTrue(
            AgentComposerTextSync.shouldApplyBoundText(
                currentText: "hello",
                boundText: "",
                hasMarkedText: false
            )
        )
    }

    func testCommandReturnsSubmitForPlainEnter() {
        let command = AgentComposerInputCommandResolver.command(
            for: #selector(NSResponder.insertNewline(_:)),
            modifierFlags: [],
            hasMarkedText: false
        )

        XCTAssertEqual(command, .submit)
    }

    func testCommandReturnsInsertNewlineForCommandEnter() {
        let command = AgentComposerInputCommandResolver.command(
            for: #selector(NSResponder.insertNewline(_:)),
            modifierFlags: [.command],
            hasMarkedText: false
        )

        XCTAssertEqual(command, .insertNewline)
    }

    func testCommandReturnsInsertNewlineForShiftEnter() {
        let command = AgentComposerInputCommandResolver.command(
            for: #selector(NSResponder.insertNewline(_:)),
            modifierFlags: [.shift],
            hasMarkedText: false
        )

        XCTAssertEqual(command, .insertNewline)
    }

    func testCommandDefersEnterWhileInputMethodHasMarkedText() {
        let command = AgentComposerInputCommandResolver.command(
            for: #selector(NSResponder.insertNewline(_:)),
            modifierFlags: [],
            hasMarkedText: true
        )

        XCTAssertEqual(command, .passthrough)
    }
}

final class LLMAgentGeneratorAdapterTests: XCTestCase {
    func testAgentChatDoesNotSetCompletionTokenCap() {
        XCTAssertNil(LLMAgentGenerationDefaults.maxTokens)
    }
}
