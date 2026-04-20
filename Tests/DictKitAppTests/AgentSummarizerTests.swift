import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import AnkiMateRPC

final class AgentSummarizerTests: XCTestCase {
    func testNextBatchSelectsOldestEligibleMessagesOutsideRecentWindow() {
        let summarizer = AgentSummarizer(
            configuration: .init(
                recentMessageLimit: 4,
                batchSize: 3
            )
        )
        let messages = (1...8).map { index in
            Self.message(
                ordinal: index,
                role: index.isMultiple(of: 2) ? .assistant : .user,
                content: .text("message-\(index)")
            )
        }

        let batch = summarizer.nextBatch(from: messages)

        XCTAssertEqual(batch?.sourceMessages.map(\.ordinal), [1, 2, 3])
    }

    func testNextBatchSkipsSupersededAndExistingSummaryMessages() {
        let summarizer = AgentSummarizer(
            configuration: .init(
                recentMessageLimit: 2,
                batchSize: 2
            )
        )
        let summaryID = UUID()
        let messages = [
            AgentChatMessage(
                id: UUID(),
                sessionID: UUID(),
                ordinal: 1,
                role: .user,
                content: .text("superseded"),
                supersededBy: summaryID
            ),
            AgentChatMessage(
                id: summaryID,
                sessionID: UUID(),
                ordinal: 2,
                role: .assistant,
                content: .summary("older summary", supersededCount: 3)
            ),
            Self.message(ordinal: 3, role: .user, content: .text("keep-3")),
            Self.message(ordinal: 4, role: .assistant, content: .text("keep-4")),
            Self.message(ordinal: 5, role: .user, content: .text("recent-5")),
            Self.message(ordinal: 6, role: .assistant, content: .text("recent-6"))
        ]

        let batch = summarizer.nextBatch(from: messages)

        XCTAssertEqual(batch?.sourceMessages.map(\.ordinal), [3, 4])
    }

    func testBuildPromptIncludesInstructionsAndSourceTranscript() throws {
        let summarizer = AgentSummarizer()
        let batch = try XCTUnwrap(
            summarizer.nextBatch(
                from: [
                    Self.message(ordinal: 1, role: .user, content: .text("Please shorten the back side.")),
                    Self.message(ordinal: 2, role: .assistant, content: .text("The current back repeats two similar senses.")),
                    Self.message(ordinal: 3, role: .user, content: .text("Keep the business example though.")),
                    Self.message(ordinal: 4, role: .assistant, content: .text("I will preserve the business example.")),
                    Self.message(ordinal: 5, role: .tool, content: .toolResult(name: "read_card_snapshot", resultJSON: #"{"word":"apple"}"#, truncated: false)),
                    Self.message(ordinal: 6, role: .user, content: .text("recent-6")),
                    Self.message(ordinal: 7, role: .assistant, content: .text("recent-7")),
                    Self.message(ordinal: 8, role: .user, content: .text("recent-8")),
                    Self.message(ordinal: 9, role: .assistant, content: .text("recent-9")),
                    Self.message(ordinal: 10, role: .user, content: .text("recent-10")),
                    Self.message(ordinal: 11, role: .assistant, content: .text("recent-11")),
                    Self.message(ordinal: 12, role: .user, content: .text("recent-12")),
                    Self.message(ordinal: 13, role: .assistant, content: .text("recent-13")),
                    Self.message(ordinal: 14, role: .user, content: .text("recent-14")),
                    Self.message(ordinal: 15, role: .assistant, content: .text("recent-15")),
                    Self.message(ordinal: 16, role: .user, content: .text("recent-16")),
                    Self.message(ordinal: 17, role: .assistant, content: .text("recent-17"))
                ]
            )
        )

        let prompt = summarizer.buildPrompt(for: batch)

        XCTAssertEqual(prompt.count, 2)
        XCTAssertEqual(prompt.first?.role, .system)
        XCTAssertTrue(prompt.first?.content.contains("Summarize earlier agent-chat history") == true)
        XCTAssertTrue(prompt.last?.content.contains("Please shorten the back side.") == true)
        XCTAssertTrue(prompt.last?.content.contains("read_card_snapshot") == true)
        XCTAssertTrue(prompt.last?.content.contains("Keep the business example though.") == true)
    }

    private static func message(
        ordinal: Int,
        role: AgentChatMessage.Role,
        content: MessageContent
    ) -> AgentChatMessage {
        AgentChatMessage(
            sessionID: UUID(),
            ordinal: ordinal,
            role: role,
            content: content
        )
    }
}
