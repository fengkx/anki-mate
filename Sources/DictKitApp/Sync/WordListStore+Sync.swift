import CryptoKit
import DictKit
import DictKitSystemDictionary
import Foundation
import SQLite3

/// Methods on WordListStore used by the sync engine.
extension WordListStore {

    // MARK: - Export for sync

    /// Load all collections including soft-deleted ones.
    func loadAllCollectionsForSync() throws -> [(record: PersistedCollectionRecord, isDeleted: Bool)] {
        try withDatabase { db in
            let sql = """
            SELECT id, name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at, is_deleted
            FROM collections
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            var results: [(PersistedCollectionRecord, Bool)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let record = PersistedCollectionRecord(
                    id: try uuidColumn(stmt, index: 0),
                    name: try textColumn(stmt, index: 1),
                    dictionaryName: try textColumn(stmt, index: 2),
                    exportSettings: CollectionExportSettings(
                        deckName: try textColumn(stmt, index: 3),
                        deckDescription: try textColumn(stmt, index: 4)
                    ),
                    createdAt: dateColumn(stmt, index: 5),
                    updatedAt: dateColumn(stmt, index: 6)
                )
                let isDeleted = sqlite3_column_int(stmt, 7) != 0
                results.append((record, isDeleted))
            }
            return results
        }
    }

    /// Load all words including soft-deleted ones, along with their collection IDs.
    func loadAllWordsForSync() throws -> [(record: PersistedWordRecord, collectionId: UUID, isDeleted: Bool, audioHash: String?)] {
        try withDatabase { db in
            let sql = """
            SELECT id, collection_id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at, is_deleted, audio_hash, ai_example_sentences, ai_definition_note
            FROM words
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            var results: [(PersistedWordRecord, UUID, Bool, String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let record = try readWordFromSyncColumns(stmt)
                let collectionId = try uuidColumn(stmt, index: 1)
                let isDeleted = sqlite3_column_int(stmt, 12) != 0
                let audioHash = nullableTextColumn(stmt, index: 13)
                results.append((record, collectionId, isDeleted, audioHash))
            }
            return results
        }
    }

    /// Read audio data for a specific word by ID.
    func audioData(forWordId id: UUID) throws -> Data? {
        try withDatabase { db in
            let sql = "SELECT audio_data FROM words WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, transientDestructor)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return blobColumn(stmt, index: 0)
        }
    }

    // MARK: - Import from sync

    /// Apply a batch of sync changes within a single transaction.
    func applySyncBatch(
        collections: [SyncCollectionRecord],
        words: [SyncWordRecord],
        audioData: [String: Data]
    ) throws {
        try withDatabase { db in
            try Self.exec(db: db, sql: "BEGIN TRANSACTION;")
            do {
                for col in collections {
                    try applySyncCollection(col, db: db)
                }
                for word in words {
                    let audio = word.audioRef.flatMap { audioData[$0] }
                    try applySyncWord(word, audioData: audio, db: db)
                }
                try Self.exec(db: db, sql: "COMMIT;")
            } catch {
                try? Self.exec(db: db, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Sync metadata

    func syncMetadata(forKey key: String) throws -> String? {
        try withDatabase { db in
            let sql = "SELECT value FROM sync_metadata WHERE key = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, transientDestructor)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return nullableTextColumn(stmt, index: 0)
        }
    }

    func setSyncMetadata(_ value: String, forKey key: String) throws {
        try withDatabase { db in
            let sql = "INSERT OR REPLACE INTO sync_metadata (key, value) VALUES (?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, transientDestructor)
            sqlite3_bind_text(stmt, 2, value, -1, transientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    // MARK: - Audio hash

    /// Check if there are local changes since the last sync.
    func hasChangesAfterLastSync() throws -> Bool {
        guard let tsString = try syncMetadata(forKey: "last_sync_timestamp"),
              let ts = TimeInterval(tsString) else {
            // Never synced — if there's any data, it's pending
            return try withDatabase { db in
                let sql = "SELECT EXISTS(SELECT 1 FROM words WHERE is_deleted = 0)"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw sqliteError(db: db)
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
                return sqlite3_column_int(stmt, 0) != 0
            }
        }

        return try withDatabase { db in
            let sql = """
            SELECT EXISTS(
                SELECT 1 FROM collections WHERE updated_at > ?
                UNION ALL
                SELECT 1 FROM words WHERE updated_at > ?
            )
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_double(stmt, 2, ts)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) != 0
        }
    }

    /// Compute and store audio hash for a word. Returns the hash.
    func updateAudioHash(forWordId id: UUID, audioData: Data) throws -> String {
        let hash = SHA256.hash(data: audioData).map { String(format: "%02x", $0) }.joined()
        try withDatabase { db in
            let sql = "UPDATE words SET audio_hash = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, hash, -1, transientDestructor)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, transientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
        return hash
    }

    static func computeAudioHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private helpers

    private func readWordFromSyncColumns(_ stmt: OpaquePointer?) throws -> PersistedWordRecord {
        // Columns: id(0), collection_id(1), normalized_word(2), display_word(3),
        // source_form(4), inflection_kind(5), expected_part_of_speech(6),
        // lookup_state_json(7), audio_data(8), created_at(9), updated_at(10),
        // last_refreshed_at(11), is_deleted(12), audio_hash(13),
        // ai_example_sentences(14), ai_definition_note(15)

        let aiSentences: [String]
        if let sentencesJson = nullableTextColumn(stmt, index: 14),
           let data = sentencesJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            aiSentences = decoded
        } else {
            aiSentences = []
        }

        return PersistedWordRecord(
            id: try uuidColumn(stmt, index: 0),
            displayWord: try textColumn(stmt, index: 3),
            normalizedWord: try textColumn(stmt, index: 2),
            sourceForm: nullableTextColumn(stmt, index: 4),
            inflectionKind: nullableTextColumn(stmt, index: 5).flatMap(InflectionKind.init(rawValue:)),
            expectedPartOfSpeech: nullableTextColumn(stmt, index: 6).flatMap(PartOfSpeech.init(rawValue:)),
            lookupState: try decodeLookupState(blobColumn(stmt, index: 7)),
            audioData: blobColumn(stmt, index: 8),
            createdAt: dateColumn(stmt, index: 9),
            updatedAt: dateColumn(stmt, index: 10),
            lastRefreshedAt: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : dateColumn(stmt, index: 11),
            aiExampleSentences: aiSentences,
            aiDefinitionNote: nullableTextColumn(stmt, index: 15)
        )
    }

    private func applySyncCollection(_ col: SyncCollectionRecord, db: OpaquePointer?) throws {
        guard let uuid = UUID(uuidString: col.id) else { return }

        // Check if it exists
        let checkSQL = "SELECT id FROM collections WHERE id = ?"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(checkStmt) }
        sqlite3_bind_text(checkStmt, 1, uuid.uuidString, -1, transientDestructor)
        let exists = sqlite3_step(checkStmt) == SQLITE_ROW

        if exists {
            let sql = """
            UPDATE collections SET name = ?, dictionary_name = ?, anki_deck_name = ?, deck_description = ?, created_at = ?, updated_at = ?, is_deleted = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, col.name, -1, transientDestructor)
            sqlite3_bind_text(stmt, 2, col.dictionaryName, -1, transientDestructor)
            sqlite3_bind_text(stmt, 3, col.ankiDeckName, -1, transientDestructor)
            sqlite3_bind_text(stmt, 4, col.deckDescription, -1, transientDestructor)
            sqlite3_bind_double(stmt, 5, col.createdAt)
            sqlite3_bind_double(stmt, 6, col.updatedAt)
            sqlite3_bind_int(stmt, 7, col.isDeleted ? 1 : 0)
            sqlite3_bind_text(stmt, 8, uuid.uuidString, -1, transientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        } else {
            let sql = """
            INSERT INTO collections (id, name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at, is_deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transientDestructor)
            sqlite3_bind_text(stmt, 2, col.name, -1, transientDestructor)
            sqlite3_bind_text(stmt, 3, col.dictionaryName, -1, transientDestructor)
            sqlite3_bind_text(stmt, 4, col.ankiDeckName, -1, transientDestructor)
            sqlite3_bind_text(stmt, 5, col.deckDescription, -1, transientDestructor)
            sqlite3_bind_double(stmt, 6, col.createdAt)
            sqlite3_bind_double(stmt, 7, col.updatedAt)
            sqlite3_bind_int(stmt, 8, col.isDeleted ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    private func applySyncWord(_ word: SyncWordRecord, audioData: Data?, db: OpaquePointer?) throws {
        guard let uuid = UUID(uuidString: word.id) else { return }

        // Decode lookup state from base64
        var lookupStateData: Data?
        if let base64 = word.lookupStateBase64 {
            lookupStateData = Data(base64Encoded: base64)
        }

        // Check if it exists
        let checkSQL = "SELECT id FROM words WHERE id = ?"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(checkStmt) }
        sqlite3_bind_text(checkStmt, 1, uuid.uuidString, -1, transientDestructor)
        let exists = sqlite3_step(checkStmt) == SQLITE_ROW

        if exists {
            let sql = """
            UPDATE words SET collection_id = ?, normalized_word = ?, display_word = ?, source_form = ?, inflection_kind = ?, expected_part_of_speech = ?, lookup_state_json = ?, audio_data = COALESCE(?, audio_data), created_at = ?, updated_at = ?, last_refreshed_at = ?, is_deleted = ?, audio_hash = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            try bindSyncWordFields(word, audioData: audioData, lookupStateData: lookupStateData, stmt: stmt)
            sqlite3_bind_text(stmt, 14, uuid.uuidString, -1, transientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        } else {
            let sql = """
            INSERT INTO words (id, collection_id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at, is_deleted, audio_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, transientDestructor)
            try bindSyncWordFields(word, audioData: audioData, lookupStateData: lookupStateData, stmt: stmt, startIndex: 2)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    private func bindSyncWordFields(
        _ word: SyncWordRecord,
        audioData: Data?,
        lookupStateData: Data?,
        stmt: OpaquePointer?,
        startIndex: Int32 = 1
    ) throws {
        var i = startIndex
        sqlite3_bind_text(stmt, i, word.collectionId, -1, transientDestructor); i += 1
        sqlite3_bind_text(stmt, i, word.normalizedWord, -1, transientDestructor); i += 1
        sqlite3_bind_text(stmt, i, word.displayWord, -1, transientDestructor); i += 1

        if let sf = word.sourceForm {
            sqlite3_bind_text(stmt, i, sf, -1, transientDestructor)
        } else { sqlite3_bind_null(stmt, i) }
        i += 1

        if let ik = word.inflectionKind {
            sqlite3_bind_text(stmt, i, ik, -1, transientDestructor)
        } else { sqlite3_bind_null(stmt, i) }
        i += 1

        if let pos = word.expectedPartOfSpeech {
            sqlite3_bind_text(stmt, i, pos, -1, transientDestructor)
        } else { sqlite3_bind_null(stmt, i) }
        i += 1

        if let data = lookupStateData {
            _ = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, i, buffer.baseAddress, Int32(buffer.count), transientDestructor)
            }
        } else { sqlite3_bind_null(stmt, i) }
        i += 1

        if let audio = audioData {
            _ = audio.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, i, buffer.baseAddress, Int32(buffer.count), transientDestructor)
            }
        } else { sqlite3_bind_null(stmt, i) }
        i += 1

        sqlite3_bind_double(stmt, i, word.createdAt); i += 1
        sqlite3_bind_double(stmt, i, word.updatedAt); i += 1

        if let lra = word.lastRefreshedAt {
            sqlite3_bind_double(stmt, i, lra)
        } else { sqlite3_bind_null(stmt, i) }
        i += 1

        sqlite3_bind_int(stmt, i, word.isDeleted ? 1 : 0); i += 1

        if let hash = word.audioRef {
            sqlite3_bind_text(stmt, i, hash, -1, transientDestructor)
        } else { sqlite3_bind_null(stmt, i) }
    }
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
