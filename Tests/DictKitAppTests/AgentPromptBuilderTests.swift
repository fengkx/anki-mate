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

        let systemPrompt = messages.first(where: { $0.role == .system })?.content.plainText ?? ""

        XCTAssertTrue(systemPrompt.contains("study assistant for Anki vocabulary cards"))
        XCTAssertTrue(systemPrompt.contains("You can only edit card content"))
        XCTAssertTrue(systemPrompt.contains("Layout, style, fonts, colors, and template changes are not supported"))
        XCTAssertTrue(systemPrompt.contains("Respond in Simplified Chinese"))
        XCTAssertEqual(messages.filter { $0.role == .system }.count, 1)
        XCTAssertEqual(messages.first?.role, .system)
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

        let combined = messages.map(\.content.plainText).joined(separator: "\n---\n")

        XCTAssertTrue(combined.contains("Current card snapshot"))
        XCTAssertTrue(combined.contains("┌─────────── FRONT"))
        XCTAssertTrue(combined.contains(#""word":"apple""#))
        XCTAssertTrue(combined.contains("Pending proposals"))
        XCTAssertTrue(combined.contains("Replace example #2 with business context"))
        XCTAssertTrue(combined.contains("Recent proposal decisions"))
        XCTAssertTrue(combined.contains("applied"))
        XCTAssertTrue(combined.contains("Add company-vs-fruit pitfall"))
    }

    func testBuildMessagesInjectsRecallSnapshotWhenAvailable() {
        let builder = AgentPromptBuilder()
        let messages = builder.buildMessages(
            context: .init(
                cardSnapshot: Self.sampleSnapshot(),
                relatedSnapshots: [Self.recallSnapshot()],
                messages: [
                    Self.message(role: .user, ordinal: 1, content: .text("recall card 的挖空我总记错"))
                ],
                tools: AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() }).definitions
            )
        )

        let combined = messages.map(\.content.plainText).joined(separator: "\n")

        XCTAssertTrue(combined.contains("Current card snapshot"))
        XCTAssertTrue(combined.contains("Related card snapshots"))
        XCTAssertTrue(combined.contains("Recall focus summary"))
        XCTAssertTrue(combined.contains("masked token: p_rpetual"))
        XCTAssertTrue(combined.contains("hidden segment: e"))
        XCTAssertTrue(combined.contains("RECALL FRONT"))
        XCTAssertTrue(combined.contains(#""kind":"recall""#))
        XCTAssertTrue(combined.contains(#""front":"p_rpetual""#))
        XCTAssertTrue(combined.contains("First infer the learner's immediate task from the user's request and the card context"))
        XCTAssertTrue(combined.contains("Prefer the information that most directly helps the learner succeed at that immediate task"))
        XCTAssertTrue(combined.contains("give discriminative help instead of broad background explanation"))
        XCTAssertTrue(combined.contains("When the user mentions a Recall Card, cloze, blank, hidden letters, front/back, or 挖空, use the Recall Card snapshot already in context"))
        XCTAssertTrue(combined.contains("For Recall Card questions, first identify the exact masked token and the hidden letters from the Recall snapshot before explaining anything else"))
        XCTAssertTrue(combined.contains("If the user asks for a mnemonic, 记忆点, or memory trick to help solve a Recall Card blank, answer in chat by default"))
        XCTAssertTrue(combined.contains("Do not call propose_mnemonic unless the user explicitly asks to add that mnemonic to the standard card"))
        XCTAssertTrue(combined.contains("If the user explicitly asks to change the Recall Card itself, prefer propose_recall_draft rather than propose_mnemonic"))
        XCTAssertTrue(combined.contains("Example recall-draft tool call"))
    }

    func testSystemPromptDiscouragesInternalLabelQuestionsBeforeProposal() {
        let registry = AgentToolRegistry(snapshotLoader: { _ in Self.sampleSnapshot() })
        let builder = AgentPromptBuilder()
        let messages = builder.buildMessages(
            context: .init(
                cardSnapshot: Self.sampleSnapshot(),
                messages: [
                    Self.message(role: .user, ordinal: 1, content: .text("帮我新增一个例句吧"))
                ],
                tools: registry.definitions
            )
        )

        let systemPrompt = messages.first(where: { $0.role == .system })?.content.plainText ?? ""

        XCTAssertTrue(systemPrompt.contains("Do not ask the user to choose between internal labels or categories before creating a proposal"))
        XCTAssertTrue(systemPrompt.contains("Default to generating the content yourself unless the user explicitly requests sourced/cited/verbatim content"))
        XCTAssertTrue(systemPrompt.contains("Existing artifacts can still be edit targets for replace/delete when the user refers to them"))
        XCTAssertTrue(systemPrompt.contains("For content edit requests, call the matching propose_* tool as soon as the action, section, and content can be inferred"))
        XCTAssertFalse(systemPrompt.contains("AI-generated"))
        XCTAssertFalse(systemPrompt.contains("natural context"))
    }

}

final class AgentContextAssemblyTests: XCTestCase {
    func testHistoryAssemblyUsesNeutralToolTraceText() {
        let builder = AgentPromptBuilder()
        let history = [
            Self.message(
                role: .assistant,
                ordinal: 1,
                content: .toolCall(
                    name: "propose_mnemonic",
                    argsJSON: #"{"operation":"add"}"#
                )
            ),
            Self.message(
                role: .assistant,
                ordinal: 2,
                content: .actionProposal(
                    ProposalRecord(
                        kind: .mnemonic,
                        operation: .add,
                        payloadJSON: #"{"text":"memory hook"}"#,
                        diffSummary: "Add mnemonic: memory hook"
                    )
                )
            ),
            Self.message(role: .user, ordinal: 3, content: .text("继续"))
        ]

        let built = builder.buildMessages(
            context: .init(
                cardSnapshot: AgentPromptBuilderTests.sampleSnapshot(),
                messages: history
            )
        )
        let combined = built.map(\.content.plainText).joined(separator: "\n")

        XCTAssertTrue(combined.contains("Assistant used tool: propose_mnemonic"))
        XCTAssertTrue(combined.contains("Tool arguments JSON:"))
        XCTAssertFalse(combined.contains("[Tool call] propose_mnemonic"))
    }

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
        let combined = built.map(\.content.plainText).joined(separator: "\n")

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
        let combined = built.map(\.content.plainText).joined(separator: "\n")

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

    static func recallSnapshot() -> CardRenderSnapshot {
        CardRenderSnapshot(
            kind: .recall,
            word: "apple",
            phonetic: "/ˈæp.əl/",
            wireframe: """
            ┌─────────── RECALL FRONT ───────────────────────┐
            │ p_rpetual                                      │
            └───────────────────────────────────────────────┘
            ┌─────────── RECALL BACK ────────────────────────┐
            │ perpetual                                      │
            └───────────────────────────────────────────────┘
            """,
            structuredJSON: #"{"kind":"recall","word":"apple","recall":{"front":"p_rpetual","back":"perpetual"}}"#,
            aiSectionOrder: []
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
