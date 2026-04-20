import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import AnkiMateRPC
@testable import DictKitAnkiExport

final class AgentPromptBuilderTests: XCTestCase {
    func testSystemPromptIncludesIdentityBoundaryAndChineseResponseDirective() {
        let builder = AgentPromptBuilder()
        let messages = builder.buildMessages(
            context: .init(
                cardSnapshot: Self.sampleSnapshot(),
                messages: [
                    Self.message(role: .user, ordinal: 1, content: .text("把第二个例句换短一点"))
                ]
            )
        )

        let systemPrompt = messages.first(where: { $0.role == .system })?.content ?? ""

        XCTAssertTrue(systemPrompt.contains("You are an Anki learner editing your own card"))
        XCTAssertTrue(systemPrompt.contains("You can only edit card content"))
        XCTAssertTrue(systemPrompt.contains("Do not modify layout, style, color, font size, section order, or template structure"))
        XCTAssertTrue(systemPrompt.contains("Respond in Simplified Chinese"))
    }

    func testBuildMessagesInjectsSnapshotPendingAndDecisionSummary() {
        let builder = AgentPromptBuilder()
        var applied = ProposalRecord(
            kind: .pitfall,
            operation: .add,
            payloadJSON: #"{"id":"pf-1","text":"Company vs fruit"}"#,
            diffSummary: "Add company-vs-fruit pitfall",
            rationale: "Avoid semantic confusion"
        )
        applied.decision = .applied

        let pending = ProposalRecord(
            kind: .example,
            operation: .replace(targetID: "ex-2"),
            payloadJSON: #"{"text":"Apple stock fell sharply.","translation":"苹果公司股价大跌。"}"#,
            diffSummary: "Replace example #2 with business context",
            rationale: "Current example is too generic"
        )

        let messages = builder.buildMessages(
            context: .init(
                cardSnapshot: Self.sampleSnapshot(),
                messages: [
                    Self.message(role: .assistant, ordinal: 1, content: .actionProposal(applied)),
                    Self.message(role: .assistant, ordinal: 2, content: .actionProposal(pending)),
                    Self.message(role: .user, ordinal: 3, content: .text("Use a more business-like example"))
                ]
            )
        )

        let combined = messages.map(\.content).joined(separator: "\n---\n")

        XCTAssertTrue(combined.contains("Current card snapshot"))
        XCTAssertTrue(combined.contains("┌─────────── FRONT"))
        XCTAssertTrue(combined.contains(#""word":"apple""#))
        XCTAssertTrue(combined.contains("Pending proposals"))
        XCTAssertTrue(combined.contains("Replace example #2 with business context"))
        XCTAssertTrue(combined.contains("Recent proposal decisions"))
        XCTAssertTrue(combined.contains("applied"))
        XCTAssertTrue(combined.contains("Add company-vs-fruit pitfall"))
    }
}

final class AgentContextAssemblyTests: XCTestCase {
    func testHistoryAssemblySkipsSupersededMessagesButKeepsSummary() {
        let builder = AgentPromptBuilder(
            configuration: .init(
                recentMessageLimit: 12,
                guaranteedRecentMessages: 5,
                maxContextTokens: 400
            )
        )
        let summaryID = UUID()
        let history = [
            AgentChatMessage(
                id: UUID(),
                sessionID: UUID(),
                ordinal: 1,
                role: .user,
                content: .text("Old detailed request that should disappear"),
                supersededBy: summaryID
            ),
            AgentChatMessage(
                id: summaryID,
                sessionID: UUID(),
                ordinal: 2,
                role: .assistant,
                content: .summary("Earlier discussion focused on shortening examples.", supersededCount: 3)
            ),
            Self.message(role: .user, ordinal: 3, content: .text("Keep the newest request visible"))
        ]

        let built = builder.buildMessages(
            context: .init(
                cardSnapshot: AgentPromptBuilderTests.sampleSnapshot(),
                messages: history
            )
        )
        let combined = built.map(\.content).joined(separator: "\n")

        XCTAssertFalse(combined.contains("Old detailed request that should disappear"))
        XCTAssertTrue(combined.contains("Earlier discussion focused on shortening examples."))
        XCTAssertTrue(combined.contains("Keep the newest request visible"))
    }

    func testHistoryAssemblyDropsOlderSummariesBeforeGuaranteedRecentMessagesWhenBudgetIsTight() {
        let builder = AgentPromptBuilder(
            configuration: .init(
                recentMessageLimit: 12,
                guaranteedRecentMessages: 5,
                maxContextTokens: 120
            )
        )

        let summary = Self.message(
            role: .assistant,
            ordinal: 1,
            content: .summary(String(repeating: "summary ", count: 80), supersededCount: 10)
        )
        let recentMessages = (2...7).map { index in
            Self.message(role: index.isMultiple(of: 2) ? .user : .assistant, ordinal: index, content: .text("recent-\(index)"))
        }

        let built = builder.buildMessages(
            context: .init(
                cardSnapshot: AgentPromptBuilderTests.sampleSnapshot(),
                messages: [summary] + recentMessages
            )
        )
        let combined = built.map(\.content).joined(separator: "\n")

        XCTAssertFalse(combined.contains("summary summary summary"))
        XCTAssertTrue(combined.contains("recent-3"))
        XCTAssertTrue(combined.contains("recent-4"))
        XCTAssertTrue(combined.contains("recent-5"))
        XCTAssertTrue(combined.contains("recent-6"))
        XCTAssertTrue(combined.contains("recent-7"))
    }

    private static func message(
        role: AgentChatMessage.Role,
        ordinal: Int,
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

private extension AgentPromptBuilderTests {
    static func sampleSnapshot() -> CardRenderSnapshot {
        CardRenderSnapshot(
            kind: .standard,
            word: "apple",
            phonetic: "/ˈæp.əl/",
            wireframe: """
            ┌─────────── FRONT ──────────────────────────────┐
            │ apple                                         │
            │ /ˈæp.əl/                                      │
            └───────────────────────────────────────────────┘
            """,
            structuredJSON: #"{"word":"apple","artifacts":{"examples":[{"id":"ex-2","text":"I ate an apple."}]}}"#,
            aiSectionOrder: [.usageCue, .examples]
        )
    }

    static func message(
        role: AgentChatMessage.Role,
        ordinal: Int,
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
