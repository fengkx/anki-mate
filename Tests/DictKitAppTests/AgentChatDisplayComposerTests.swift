import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import DictKitApp

final class AgentChatDisplayComposerTests: XCTestCase {
    func testComposeEmbedsAdjacentProposalToolCall() {
        let sessionID = UUID()
        let toolCall = AgentChatMessage(
            sessionID: sessionID,
            ordinal: 1,
            role: .assistant,
            content: .toolCall(
                name: "propose_pitfall",
                argsJSON: #"{"diffSummary":"Add a pitfall","operation":"add","payload":{"text":"Do not confuse Apple the company with the fruit."}}"#
            )
        )
        let proposal = ProposalRecord(
            kind: .pitfall,
            operation: .add,
            payloadJSON: #"{"text":"Do not confuse Apple the company with the fruit."}"#,
            diffSummary: "Add a pitfall"
        )
        let proposalMessage = AgentChatMessage(
            sessionID: sessionID,
            ordinal: 2,
            role: .assistant,
            content: .actionProposal(proposal)
        )

        let rows = AgentChatDisplayComposer.compose([toolCall, proposalMessage])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].message.id, proposalMessage.id)
        XCTAssertEqual(rows[0].embeddedToolCall?.name, "propose_pitfall")
        XCTAssertEqual(
            rows[0].embeddedToolCall?.argsJSON,
            #"{"diffSummary":"Add a pitfall","operation":"add","payload":{"text":"Do not confuse Apple the company with the fruit."}}"#
        )
    }

    func testComposeKeepsStandaloneToolCallVisible() {
        let sessionID = UUID()
        let toolCall = AgentChatMessage(
            sessionID: sessionID,
            ordinal: 1,
            role: .assistant,
            content: .toolCall(name: "read_card_snapshot", argsJSON: #"{}"#)
        )

        let rows = AgentChatDisplayComposer.compose([toolCall])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].message.id, toolCall.id)
        XCTAssertNil(rows[0].embeddedToolCall)
    }
}
