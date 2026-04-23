import DictKit
import DictKitAnkiExport
import Foundation
import SQLite3
import XCTest
@testable import AnkiMateLLM
@testable import DictKitApp

final class AgentSessionStoreTests: XCTestCase {
    func testSessionCRUDAndMessageOrdinalsRoundTrip() throws {
        let (wordListStore, wordID) = try makeStores()
        let store = AgentSessionStore(databaseURL: wordListStore.databaseURL)

        let session = try store.upsertSession(for: wordID)
        let first = try store.addMessage(
            sessionID: session.id,
            role: .user,
            content: .text("make this card shorter")
        )
        let second = try store.addMessage(
            sessionID: session.id,
            role: .assistant,
            content: .summary("Earlier discussion summary", supersededCount: 3)
        )

        let reloadedSession = try XCTUnwrap(try store.session(for: wordID))
        let messages = try store.loadMessages(sessionID: session.id)

        XCTAssertEqual(reloadedSession.wordItemID, wordID)
        XCTAssertEqual(messages.map(\.ordinal), [1, 2])
        XCTAssertEqual(messages.map(\.id), [first.id, second.id])
    }

    func testUserInputAttachmentsRoundTripThroughContentJSON() throws {
        let (wordListStore, wordID) = try makeStores()
        let store = AgentSessionStore(databaseURL: wordListStore.databaseURL)
        let session = try store.upsertSession(for: wordID)
        let attachment = AgentAttachment(
            kind: .textFile,
            mimeType: "text/plain",
            fileName: "note.txt",
            relativePath: "agent/session/note.txt",
            byteSize: 11,
            extractedTextPreview: "hello world",
            characterCount: 11
        )

        _ = try store.addMessage(
            sessionID: session.id,
            role: .user,
            content: .userInput(text: "read this", attachments: [attachment])
        )

        let reloaded = try XCTUnwrap(try store.loadMessages(sessionID: session.id).only)
        guard case .userInput(let text, let attachments) = reloaded.content else {
            return XCTFail("Expected user input content")
        }
        XCTAssertEqual(text, "read this")
        XCTAssertEqual(attachments, [attachment])
    }

    func testDeletingWordCascadesSessionsAndMessages() throws {
        let (wordListStore, wordID) = try makeStores()
        let store = AgentSessionStore(databaseURL: wordListStore.databaseURL)
        let session = try store.upsertSession(for: wordID)
        _ = try store.addMessage(sessionID: session.id, role: .user, content: .text("hello"))

        try wordListStore.withDatabase { db in
            try WordListStore.exec(db: db, sql: "DELETE FROM word_payloads;")
            try WordListStore.exec(db: db, sql: "DELETE FROM words;")
        }

        XCTAssertNil(try store.session(for: wordID))
        XCTAssertTrue(try store.loadMessages(sessionID: session.id).isEmpty)
    }

    func testCrashRecoveryCancelsStreamingMessages() throws {
        let (wordListStore, wordID) = try makeStores()
        let store = AgentSessionStore(databaseURL: wordListStore.databaseURL)
        let session = try store.upsertSession(for: wordID)
        _ = try store.addMessage(
            sessionID: session.id,
            role: .assistant,
            status: .streaming,
            content: .text("partial")
        )

        let updatedCount = try store.cancelInterruptedStreamingMessages()
        let messages = try store.loadMessages(sessionID: session.id)

        XCTAssertEqual(updatedCount, 1)
        XCTAssertEqual(messages.only?.status, .canceled)
        XCTAssertEqual(messages.only?.interrupted, true)
    }

    func testDeleteMessagesHandlesBatchesLargerThanSQLiteVariableLimit() throws {
        let (wordListStore, wordID) = try makeStores()
        let store = AgentSessionStore(databaseURL: wordListStore.databaseURL)
        let session = try store.upsertSession(for: wordID)
        let messages = try (0..<1_050).map { index in
            try store.addMessage(
                sessionID: session.id,
                role: .user,
                content: .text("message \(index)")
            )
        }

        try store.deleteMessages(ids: messages.map(\.id))

        XCTAssertTrue(try store.loadMessages(sessionID: session.id).isEmpty)
    }

    func testProposalReconciliationMarksPendingPitfallAsAppliedWhenArtifactAlreadyExists() throws {
        let (wordListStore, wordID) = try makeStores()
        let store = AgentSessionStore(databaseURL: wordListStore.databaseURL)
        let session = try store.upsertSession(for: wordID)
        let proposedArtifact = PitfallArtifact(id: "pf-1", text: "Do not confuse Apple the company with apple the fruit.")
        let payloadData = try JSONEncoder().encode(proposedArtifact)
        let payloadJSON = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
        let proposal = ProposalRecord(
            kind: .pitfall,
            operation: .add,
            payloadJSON: payloadJSON,
            diffSummary: "Add company-vs-fruit pitfall",
            rationale: "This confusion is easy to make while reviewing."
        )

        let message = try store.addMessage(
            sessionID: session.id,
            role: .assistant,
            content: .actionProposal(proposal)
        )

        let updated = try store.reconcilePendingProposals { requestedWordID in
            XCTAssertEqual(requestedWordID, wordID)
            return AIArtifacts(
                pitfalls: AIArtifactSlot(
                    suggested: [proposedArtifact],
                    accepted: nil
                )
            )
        }
        let reloaded = try XCTUnwrap(try store.loadMessages(sessionID: session.id).only(where: { $0.id == message.id }))
        guard case .actionProposal(let reconciledProposal) = reloaded.content else {
            return XCTFail("Expected proposal content")
        }

        XCTAssertEqual(updated, 1)
        XCTAssertEqual(reconciledProposal.decision, .applied)
        XCTAssertEqual(reloaded.status, .completed)
    }

    private func makeStores() throws -> (WordListStore, UUID) {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let wordListStore = try WordListStore(databaseURL: baseURL.appendingPathComponent("word-list.sqlite3"))
        let collection = try XCTUnwrap(try wordListStore.loadCollections().only)
        let word = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 20)
        )
        _ = try wordListStore.upsertWord(word, into: collection.id)
        return (wordListStore, word.id)
    }

    private static func makeLookupResult(query: String, definition: String, examples: [String]) -> LookupResult {
        LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: query,
                    pronunciations: [
                        Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)
                    ],
                    lexicalEntries: [
                        LexicalEntry(
                            partOfSpeech: .noun,
                            partOfSpeechLabel: "noun",
                            displayIndex: 0,
                            pronunciations: [
                                Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)
                            ],
                            senses: [
                                Sense(
                                    number: 1,
                                    semanticHint: nil,
                                    definition: definition,
                                    examples: examples,
                                    registers: [],
                                    countability: nil
                                )
                            ],
                            grammar: [],
                            inflections: []
                        )
                    ],
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }
}

private extension Array {
    func only(where predicate: (Element) -> Bool) -> Element? {
        let matches = filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }

    var only: Element? {
        count == 1 ? first : nil
    }
}
