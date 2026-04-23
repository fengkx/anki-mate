import AnkiMateLLM
import DictKitAnkiExport
import Foundation
import SQLite3

struct AgentSessionStore: AgentSessionPersisting {
    let databaseURL: URL

    func upsertSession(
        for wordID: UUID,
        preferences: AgentSessionPreferences = .init()
    ) throws -> AgentChatSession {
        if var existing = try session(for: wordID) {
            guard existing.preferences != preferences else {
                return existing
            }

            existing.preferences = preferences
            existing.updatedAt = Date()
            try withDatabase { db in
                let sql = """
                UPDATE agent_sessions
                SET updated_at = ?, preferences_json = ?, schema_version = ?
                WHERE id = ?
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw sqliteError(db: db)
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, existing.updatedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 2, try encodePreferences(existing.preferences), -1, agentTransientDestructor)
                sqlite3_bind_int(stmt, 3, Int32(existing.schemaVersion))
                sqlite3_bind_text(stmt, 4, existing.id.uuidString, -1, agentTransientDestructor)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw sqliteError(db: db)
                }
            }
            return existing
        }

        let now = Date()
        let session = AgentChatSession(
            wordItemID: wordID,
            createdAt: now,
            updatedAt: now,
            preferences: preferences
        )

        try withDatabase { db in
            let sql = """
            INSERT INTO agent_sessions (id, word_id, created_at, updated_at, schema_version, preferences_json)
            VALUES (?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, session.id.uuidString, -1, agentTransientDestructor)
            sqlite3_bind_text(stmt, 2, wordID.uuidString, -1, agentTransientDestructor)
            sqlite3_bind_double(stmt, 3, session.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, session.updatedAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 5, Int32(session.schemaVersion))
            sqlite3_bind_text(stmt, 6, try encodePreferences(session.preferences), -1, agentTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }

        return session
    }

    func session(for wordID: UUID) throws -> AgentChatSession? {
        try withDatabase { db in
            let sql = """
            SELECT id, word_id, created_at, updated_at, schema_version, preferences_json
            FROM agent_sessions
            WHERE word_id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, wordID.uuidString, -1, agentTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return try decodeSession(stmt)
        }
    }

    func loadMessages(sessionID: UUID) throws -> [AgentChatMessage] {
        try withDatabase { db in
            let sql = """
            SELECT id, session_id, ordinal, role, status, created_at, content_json, proposal_decision, superseded_by, interrupted
            FROM agent_messages
            WHERE session_id = ?
            ORDER BY ordinal ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, sessionID.uuidString, -1, agentTransientDestructor)

            var messages: [AgentChatMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                messages.append(try decodeMessage(stmt))
            }
            return messages
        }
    }

    @discardableResult
    func addMessage(
        sessionID: UUID,
        role: AgentChatMessage.Role,
        status: AgentChatMessage.Status = .completed,
        content: MessageContent,
        createdAt: Date = Date(),
        supersededBy: UUID? = nil,
        interrupted: Bool = false
    ) throws -> AgentChatMessage {
        try withDatabase { db in
            let ordinal = try nextOrdinal(sessionID: sessionID, db: db)
            let message = AgentChatMessage(
                sessionID: sessionID,
                ordinal: ordinal,
                role: role,
                createdAt: createdAt,
                status: status,
                content: content,
                supersededBy: supersededBy,
                interrupted: interrupted
            )

            let sql = """
            INSERT INTO agent_messages (
              id, session_id, ordinal, role, kind, status, created_at, content_json,
              proposal_decision, tool_name, superseded_by, interrupted
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            try bindMessage(message, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }

            try touchSession(sessionID: sessionID, updatedAt: createdAt, db: db)
            return message
        }
    }

    func deleteMessages(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try withDatabase { db in
            for batch in ids.chunked(maxSize: 900) {
                try autoreleasepool {
                    let placeholders = batch.map { _ in "?" }.joined(separator: ", ")
                    let sql = "DELETE FROM agent_messages WHERE id IN (\(placeholders))"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                        throw sqliteError(db: db)
                    }
                    defer { sqlite3_finalize(stmt) }
                    for (index, id) in batch.enumerated() {
                        sqlite3_bind_text(stmt, Int32(index + 1), id.uuidString, -1, agentTransientDestructor)
                    }
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw sqliteError(db: db)
                    }
                }
            }
        }
    }

    func clearMessages(sessionID: UUID) throws {
        try withDatabase { db in
            let sql = "DELETE FROM agent_messages WHERE session_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, sessionID.uuidString, -1, agentTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
            try touchSession(sessionID: sessionID, updatedAt: Date(), db: db)
        }
    }

    func resetSession(for wordID: UUID) throws {
        try withDatabase { db in
            let sql = "DELETE FROM agent_sessions WHERE word_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, wordID.uuidString, -1, agentTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    @discardableResult
    func cancelInterruptedStreamingMessages() throws -> Int {
        try withDatabase { db in
            let sql = """
            UPDATE agent_messages
            SET status = ?, interrupted = 1
            WHERE status = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, AgentChatMessage.Status.canceled.rawValue, -1, agentTransientDestructor)
            sqlite3_bind_text(stmt, 2, AgentChatMessage.Status.streaming.rawValue, -1, agentTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
            return Int(sqlite3_changes(db))
        }
    }

    @discardableResult
    func reconcilePendingProposals(
        loadArtifacts: (UUID) throws -> AIArtifacts
    ) throws -> Int {
        struct PendingProposalRow {
            let messageID: UUID
            let wordID: UUID
            var proposal: ProposalRecord
        }

        let rows: [PendingProposalRow] = try withDatabase { db in
            let sql = """
            SELECT m.id, s.word_id, m.content_json
            FROM agent_messages m
            JOIN agent_sessions s ON s.id = m.session_id
            WHERE m.proposal_decision = 'pending'
            ORDER BY m.created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            var rows: [PendingProposalRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let content = try decodeContent(from: try textColumn(stmt, index: 2))
                guard case .actionProposal(let proposal) = content else { continue }
                rows.append(
                    PendingProposalRow(
                        messageID: try uuidColumn(stmt, index: 0),
                        wordID: try uuidColumn(stmt, index: 1),
                        proposal: proposal
                    )
                )
            }
            return rows
        }

        var updatedCount = 0
        for row in rows {
            let artifacts = try loadArtifacts(row.wordID)
            guard try proposalMatchesArtifacts(row.proposal, artifacts: artifacts) else {
                continue
            }
            var updatedProposal = row.proposal
            updatedProposal.decision = .applied
            updatedProposal.decidedAt = updatedProposal.decidedAt ?? Date()
            _ = try updateProposal(messageID: row.messageID, proposal: updatedProposal)
            updatedCount += 1
        }

        return updatedCount
    }

    func updateProposal(messageID: UUID, proposal: ProposalRecord) throws -> AgentChatMessage {
        let content = MessageContent.actionProposal(proposal)
        return try withDatabase { db in
            let sql = """
            UPDATE agent_messages
            SET content_json = ?, proposal_decision = ?, status = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, try encodeContent(content), -1, agentTransientDestructor)
            sqlite3_bind_text(stmt, 2, proposal.decision.rawValue, -1, agentTransientDestructor)
            sqlite3_bind_text(stmt, 3, AgentChatMessage.Status.completed.rawValue, -1, agentTransientDestructor)
            sqlite3_bind_text(stmt, 4, messageID.uuidString, -1, agentTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }

            let selectSQL = """
            SELECT id, session_id, ordinal, role, status, created_at, content_json, proposal_decision, superseded_by, interrupted
            FROM agent_messages
            WHERE id = ?
            """
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(selectStmt) }
            sqlite3_bind_text(selectStmt, 1, messageID.uuidString, -1, agentTransientDestructor)
            guard sqlite3_step(selectStmt) == SQLITE_ROW else {
                throw WordListStoreError.validationFailed("updated proposal message not found")
            }
            return try decodeMessage(selectStmt)
        }
    }

    private func proposalMatchesArtifacts(_ proposal: ProposalRecord, artifacts: AIArtifacts) throws -> Bool {
        switch proposal.kind {
        case .usageCue:
            let note = try JSONDecoder().decode(DefinitionNoteArtifact.self, from: payloadData(proposal.payloadJSON))
            return artifacts.definitionNote.suggested?.text == note.text ||
                artifacts.definitionNote.accepted?.text == note.text
        case .example:
            let example = try JSONDecoder().decode(ExampleSentenceArtifact.self, from: payloadData(proposal.payloadJSON))
            return artifactTexts(artifacts.exampleSentences.suggested).contains(example.text) ||
                artifactTexts(artifacts.exampleSentences.accepted).contains(example.text)
        case .recallDraft:
            let draft = try JSONDecoder().decode(RecallCardDraft.self, from: payloadData(proposal.payloadJSON))
            return (artifacts.recallCardDrafts.suggested ?? []).contains(draft) ||
                (artifacts.recallCardDrafts.accepted ?? []).contains(draft)
        case .pitfall:
            let pitfall = try JSONDecoder().decode(PitfallArtifact.self, from: payloadData(proposal.payloadJSON))
            return containsPitfall(pitfall, in: artifacts)
        case .mnemonic:
            let mnemonic = try JSONDecoder().decode(MnemonicArtifact.self, from: payloadData(proposal.payloadJSON))
            return containsMnemonic(mnemonic, in: artifacts)
        case .collocation:
            let collocation = try JSONDecoder().decode(CollocationArtifact.self, from: payloadData(proposal.payloadJSON))
            return containsCollocation(collocation, in: artifacts)
        case .deleteAccepted:
            return false
        }
    }

    private func containsPitfall(_ candidate: PitfallArtifact, in artifacts: AIArtifacts) -> Bool {
        containsArtifact(candidate.id, text: candidate.text, in: artifacts.pitfalls.suggested, keyPath: \.text) ||
            containsArtifact(candidate.id, text: candidate.text, in: artifacts.pitfalls.accepted, keyPath: \.text)
    }

    private func containsMnemonic(_ candidate: MnemonicArtifact, in artifacts: AIArtifacts) -> Bool {
        containsArtifact(candidate.id, text: candidate.text, in: artifacts.mnemonics.suggested, keyPath: \.text) ||
            containsArtifact(candidate.id, text: candidate.text, in: artifacts.mnemonics.accepted, keyPath: \.text)
    }

    private func containsCollocation(_ candidate: CollocationArtifact, in artifacts: AIArtifacts) -> Bool {
        containsArtifact(candidate.id, text: candidate.phrase, in: artifacts.collocations.suggested, keyPath: \.phrase) ||
            containsArtifact(candidate.id, text: candidate.phrase, in: artifacts.collocations.accepted, keyPath: \.phrase)
    }

    private func containsArtifact<Value>(
        _ id: String?,
        text: String,
        in values: [Value]?,
        keyPath: KeyPath<Value, String>
    ) -> Bool where Value: IdentifiableArtifact {
        guard let values else { return false }
        return values.contains { item in
            if let id, let itemID = item.id, itemID == id {
                return true
            }
            return item[keyPath: keyPath] == text
        }
    }

    private func artifactTexts(_ values: [ExampleSentenceArtifact]?) -> [String] {
        values?.map(\.text) ?? []
    }

    private func payloadData(_ payloadJSON: String) throws -> Data {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw WordListStoreError.validationFailed("invalid proposal payload json")
        }
        return data
    }

    private func nextOrdinal(sessionID: UUID, db: OpaquePointer?) throws -> Int {
        let sql = "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM agent_messages WHERE session_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID.uuidString, -1, agentTransientDestructor)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WordListStoreError.sqlError("cannot read next agent message ordinal")
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func bindMessage(_ message: AgentChatMessage, stmt: OpaquePointer?) throws {
        sqlite3_bind_text(stmt, 1, message.id.uuidString, -1, agentTransientDestructor)
        sqlite3_bind_text(stmt, 2, message.sessionID.uuidString, -1, agentTransientDestructor)
        sqlite3_bind_int(stmt, 3, Int32(message.ordinal))
        sqlite3_bind_text(stmt, 4, message.role.rawValue, -1, agentTransientDestructor)
        sqlite3_bind_text(stmt, 5, kind(for: message.content), -1, agentTransientDestructor)
        sqlite3_bind_text(stmt, 6, message.status.rawValue, -1, agentTransientDestructor)
        sqlite3_bind_double(stmt, 7, message.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 8, try encodeContent(message.content), -1, agentTransientDestructor)
        bindNullableText(proposalDecision(for: message.content), stmt: stmt, index: 9)
        bindNullableText(toolName(for: message.content), stmt: stmt, index: 10)
        bindNullableText(message.supersededBy?.uuidString, stmt: stmt, index: 11)
        sqlite3_bind_int(stmt, 12, message.interrupted ? 1 : 0)
    }

    private func decodeSession(_ stmt: OpaquePointer?) throws -> AgentChatSession {
        AgentChatSession(
            id: try uuidColumn(stmt, index: 0),
            wordItemID: try uuidColumn(stmt, index: 1),
            createdAt: dateColumn(stmt, index: 2),
            updatedAt: dateColumn(stmt, index: 3),
            schemaVersion: Int(sqlite3_column_int(stmt, 4)),
            preferences: try decodePreferences(nullableTextColumn(stmt, index: 5))
        )
    }

    private func decodeMessage(_ stmt: OpaquePointer?) throws -> AgentChatMessage {
        let decodedContent = try decodeContent(from: try textColumn(stmt, index: 6))
        return AgentChatMessage(
            id: try uuidColumn(stmt, index: 0),
            sessionID: try uuidColumn(stmt, index: 1),
            ordinal: Int(sqlite3_column_int(stmt, 2)),
            role: try decodeRole(textColumn(stmt, index: 3)),
            createdAt: dateColumn(stmt, index: 5),
            status: try decodeStatus(textColumn(stmt, index: 4)),
            content: applyStoredDecision(decodedContent, decisionRawValue: nullableTextColumn(stmt, index: 7)),
            supersededBy: nullableTextColumn(stmt, index: 8).flatMap(UUID.init(uuidString:)),
            interrupted: sqlite3_column_int(stmt, 9) != 0
        )
    }

    private func touchSession(sessionID: UUID, updatedAt: Date, db: OpaquePointer?) throws {
        let sql = "UPDATE agent_sessions SET updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, sessionID.uuidString, -1, agentTransientDestructor)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db: db)
        }
    }

    private func encodePreferences(_ preferences: AgentSessionPreferences) throws -> String {
        let data = try JSONEncoder().encode(preferences)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WordListStoreError.validationFailed("failed to encode agent preferences")
        }
        return json
    }

    private func decodePreferences(_ json: String?) throws -> AgentSessionPreferences {
        guard let json, let data = json.data(using: .utf8) else {
            return .init()
        }
        return try JSONDecoder().decode(AgentSessionPreferences.self, from: data)
    }

    private func encodeContent(_ content: MessageContent) throws -> String {
        let data = try JSONEncoder().encode(content)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WordListStoreError.validationFailed("failed to encode agent message content")
        }
        return json
    }

    private func decodeContent(from json: String) throws -> MessageContent {
        guard let data = json.data(using: .utf8) else {
            throw WordListStoreError.validationFailed("invalid agent message content")
        }
        return try JSONDecoder().decode(MessageContent.self, from: data)
    }

    private func applyStoredDecision(_ content: MessageContent, decisionRawValue: String?) -> MessageContent {
        guard case .actionProposal(var proposal) = content,
              let decisionRawValue,
              let decision = ProposalRecord.Decision(rawValue: decisionRawValue) else {
            return content
        }
        proposal.decision = decision
        return .actionProposal(proposal)
    }

    private func kind(for content: MessageContent) -> String {
        switch content {
        case .text:
            return "text"
        case .userInput:
            return "user_input"
        case .toolCall:
            return "tool_call"
        case .toolResult:
            return "tool_result"
        case .actionProposal:
            return "proposal"
        case .summary:
            return "summary"
        case .error:
            return "error"
        case .layoutRequestDeclined:
            return "layout_request_declined"
        }
    }

    private func proposalDecision(for content: MessageContent) -> String? {
        guard case .actionProposal(let proposal) = content else { return nil }
        return proposal.decision.rawValue
    }

    private func toolName(for content: MessageContent) -> String? {
        switch content {
        case .toolCall(let name, _), .toolResult(let name, _, _):
            return name
        default:
            return nil
        }
    }

    private func decodeRole(_ rawValue: String) throws -> AgentChatMessage.Role {
        guard let role = AgentChatMessage.Role(rawValue: rawValue) else {
            throw WordListStoreError.validationFailed("invalid agent role")
        }
        return role
    }

    private func decodeStatus(_ rawValue: String) throws -> AgentChatMessage.Status {
        guard let status = AgentChatMessage.Status(rawValue: rawValue) else {
            throw WordListStoreError.validationFailed("invalid agent status")
        }
        return status
    }

    private func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw WordListStoreError.cannotOpenDatabase(message)
        }
        defer { sqlite3_close(db) }
        try WordListStore.exec(db: db, sql: "PRAGMA foreign_keys = ON;")
        return try body(db)
    }

    private func uuidColumn(_ stmt: OpaquePointer?, index: Int32) throws -> UUID {
        let value = try textColumn(stmt, index: index)
        guard let uuid = UUID(uuidString: value) else {
            throw WordListStoreError.validationFailed("invalid UUID column")
        }
        return uuid
    }

    private func textColumn(_ stmt: OpaquePointer?, index: Int32) throws -> String {
        guard let value = sqlite3_column_text(stmt, index) else {
            throw WordListStoreError.validationFailed("missing text column \(index)")
        }
        return String(cString: value)
    }

    private func nullableTextColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let value = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: value)
    }

    private func dateColumn(_ stmt: OpaquePointer?, index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    private func bindNullableText(_ value: String?, stmt: OpaquePointer?, index: Int32) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, agentTransientDestructor)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func sqliteError(db: OpaquePointer?) -> WordListStoreError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .sqlError(message)
    }
}

private protocol IdentifiableArtifact {
    var id: String? { get }
}

extension PitfallArtifact: IdentifiableArtifact {}
extension MnemonicArtifact: IdentifiableArtifact {}
extension CollocationArtifact: IdentifiableArtifact {}

private extension Array {
    func chunked(maxSize: Int) -> [ArraySlice<Element>] {
        guard maxSize > 0 else { return [] }
        return stride(from: startIndex, to: endIndex, by: maxSize).map { start in
            let end = Swift.min(start + maxSize, endIndex)
            return self[start..<end]
        }
    }
}

private let agentTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
