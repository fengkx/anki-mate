import CryptoKit
import DictKit
import DictKitAnkiExport
import DictKitSystemDictionary
import Foundation
import SQLite3

extension WordListStore {
    static let syncWhitelistedTableNames = [
        "collections",
        "words",
        "word_payloads"
    ]

    struct SyncCollectionSnapshot: Equatable {
        let record: PersistedCollectionRecord
        let deletedAt: Date?
    }

    struct SyncWordSnapshot: Equatable {
        let record: PersistedWordRecord
        let collectionId: UUID
        let deletedAt: Date?
        let payloadUpdatedAt: Date
        let audioHash: String?
    }

    func loadAllCollectionsForSync() throws -> [SyncCollectionSnapshot] {
        try withDatabase { db in
            let sql = """
            SELECT id, name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at, deleted_at
            FROM collections
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            var results: [SyncCollectionSnapshot] = []
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
                let deletedAt = nullableDateColumn(stmt, index: 7)
                results.append(SyncCollectionSnapshot(record: record, deletedAt: deletedAt))
            }
            return results
        }
    }

    func loadAllWordsForSync() throws -> [SyncWordSnapshot] {
        try withDatabase { db in
            let sql = """
            SELECT
              w.id, w.collection_id, w.normalized_word, w.display_word, w.source_form, w.inflection_kind,
              w.expected_part_of_speech, w.created_at, w.updated_at, w.deleted_at,
              p.lookup_state_json, p.lookup_refreshed_at, p.audio_blob, p.audio_sha256, p.ai_artifacts_json, p.payload_updated_at
            FROM words w
            LEFT JOIN word_payloads p ON p.word_id = w.id
            ORDER BY w.created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            var results: [SyncWordSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let record = PersistedWordRecord(
                    id: try uuidColumn(stmt, index: 0),
                    displayWord: try textColumn(stmt, index: 3),
                    normalizedWord: try textColumn(stmt, index: 2),
                    sourceForm: nullableTextColumn(stmt, index: 4),
                    inflectionKind: nullableTextColumn(stmt, index: 5).flatMap(InflectionKind.init(rawValue:)),
                    expectedPartOfSpeech: nullableTextColumn(stmt, index: 6).flatMap(PartOfSpeech.init(rawValue:)),
                    lookupState: try decodeLookupState(blobColumn(stmt, index: 10)),
                    audioData: blobColumn(stmt, index: 12),
                    createdAt: dateColumn(stmt, index: 7),
                    updatedAt: dateColumn(stmt, index: 8),
                    lastRefreshedAt: nullableDateColumn(stmt, index: 11),
                    aiArtifacts: decodeAIArtifacts(json: nullableTextColumn(stmt, index: 14))
                )
                let collectionId = try uuidColumn(stmt, index: 1)
                let deletedAt = nullableDateColumn(stmt, index: 9)
                let payloadUpdatedAt = nullableDateColumn(stmt, index: 15) ?? record.updatedAt
                let audioHash = nullableTextColumn(stmt, index: 13)
                results.append(
                    SyncWordSnapshot(
                        record: record,
                        collectionId: collectionId,
                        deletedAt: deletedAt,
                        payloadUpdatedAt: payloadUpdatedAt,
                        audioHash: audioHash
                    )
                )
            }
            return results
        }
    }

    func audioData(forWordId id: UUID) throws -> Data? {
        try withDatabase { db in
            let sql = "SELECT audio_blob FROM word_payloads WHERE word_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, syncTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return blobColumn(stmt, index: 0)
        }
    }

    func applySyncBatch(
        collections: [SyncCollectionRecord],
        words: [SyncWordRecord],
        audioData: [String: Data]
    ) throws {
        try withDatabase { db in
            try Self.exec(db: db, sql: "BEGIN TRANSACTION;")
            do {
                for collection in collections {
                    try applySyncCollection(collection, db: db)
                }
                for word in words {
                    let audio = word.payload.audioRef.flatMap { audioData[$0] }
                    try applySyncWord(word, audioData: audio, db: db)
                }
                try Self.exec(db: db, sql: "COMMIT;")
            } catch {
                try? Self.exec(db: db, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    func resetLocalSyncContent() throws {
        try withDatabase { db in
            try Self.exec(db: db, sql: "BEGIN TRANSACTION;")
            do {
                try Self.exec(db: db, sql: "DELETE FROM word_payloads;")
                try Self.exec(db: db, sql: "DELETE FROM words;")
                try Self.exec(db: db, sql: "DELETE FROM collections;")
                try Self.exec(db: db, sql: "COMMIT;")
            } catch {
                try? Self.exec(db: db, sql: "ROLLBACK;")
                throw error
            }
        }
    }

    func syncMetadata(forKey key: String) throws -> String? {
        try withDatabase { db in
            let sql = "SELECT value FROM sync_state WHERE key = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, syncTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return nullableTextColumn(stmt, index: 0)
        }
    }

    func setSyncMetadata(_ value: String, forKey key: String) throws {
        try withDatabase { db in
            let sql = "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, syncTransientDestructor)
            sqlite3_bind_text(stmt, 2, value, -1, syncTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    func hasChangesAfterLastSync() throws -> Bool {
        guard let tsString = try syncMetadata(forKey: "last_sync_timestamp"),
              let ts = TimeInterval(tsString) else {
            return try withDatabase { db in
                let sql = """
                SELECT
                    EXISTS(SELECT 1 FROM collections LIMIT 1) OR
                    EXISTS(SELECT 1 FROM words LIMIT 1) OR
                    EXISTS(SELECT 1 FROM word_payloads LIMIT 1)
                """
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
                UNION ALL
                SELECT 1 FROM word_payloads WHERE payload_updated_at > ?
            )
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_double(stmt, 2, ts)
            sqlite3_bind_double(stmt, 3, ts)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) != 0
        }
    }

    func isBootstrapLocalState() throws -> Bool {
        let collections = try loadCollections()
        let words = try loadAllWords()
        let hasLastSync = try syncMetadata(forKey: "last_sync_timestamp") != nil
        guard !hasLastSync, words.isEmpty, collections.count == 1 else { return false }
        let collection = collections[0]
        return collection.name == "Default" &&
            collection.dictionaryName.isEmpty &&
            collection.ankiDeckName == "Default" &&
            collection.ankiDeckDescription.isEmpty
    }

    func updateAudioHash(forWordId id: UUID, audioData: Data) throws -> String {
        let hash = Self.computeAudioHash(audioData)
        try withDatabase { db in
            let sql = "UPDATE word_payloads SET audio_sha256 = ?, payload_updated_at = ? WHERE word_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, hash, -1, syncTransientDestructor)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id.uuidString, -1, syncTransientDestructor)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
        return hash
    }

    static func computeAudioHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func applySyncCollection(_ collection: SyncCollectionRecord, db: OpaquePointer?) throws {
        guard let uuid = UUID(uuidString: collection.id) else { return }
        let deletedAt = collection.deletedAt ?? 0

        let exists = try rowExists(
            db: db,
            sql: "SELECT 1 FROM collections WHERE id = ?",
            bind: { stmt in sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, syncTransientDestructor) }
        )

        let sql: String
        if exists {
            sql = """
            UPDATE collections
            SET name = ?, dictionary_name = ?, anki_deck_name = ?, deck_description = ?, created_at = ?, updated_at = ?, deleted_at = ?
            WHERE id = ?
            """
        } else {
            sql = """
            INSERT INTO collections (name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at, deleted_at, id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collection.name, -1, syncTransientDestructor)
        sqlite3_bind_text(stmt, 2, collection.dictionaryName, -1, syncTransientDestructor)
        sqlite3_bind_text(stmt, 3, collection.ankiDeckName, -1, syncTransientDestructor)
        sqlite3_bind_text(stmt, 4, collection.deckDescription, -1, syncTransientDestructor)
        sqlite3_bind_double(stmt, 5, collection.createdAt)
        sqlite3_bind_double(stmt, 6, collection.updatedAt)
        if collection.deletedAt != nil {
            sqlite3_bind_double(stmt, 7, deletedAt)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, uuid.uuidString, -1, syncTransientDestructor)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db: db)
        }
    }

    private func applySyncWord(_ word: SyncWordRecord, audioData: Data?, db: OpaquePointer?) throws {
        guard let uuid = UUID(uuidString: word.id) else { return }

        let exists = try rowExists(
            db: db,
            sql: "SELECT 1 FROM words WHERE id = ?",
            bind: { stmt in sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, syncTransientDestructor) }
        )

        let wordSQL: String
        if exists {
            wordSQL = """
            UPDATE words
            SET collection_id = ?, normalized_word = ?, display_word = ?, source_form = ?, inflection_kind = ?, expected_part_of_speech = ?, created_at = ?, updated_at = ?, deleted_at = ?
            WHERE id = ?
            """
        } else {
            wordSQL = """
            INSERT INTO words (collection_id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, created_at, updated_at, deleted_at, id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        }

        var wordStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, wordSQL, -1, &wordStmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(wordStmt) }

        bindSyncWordCore(word, stmt: wordStmt)
        guard sqlite3_step(wordStmt) == SQLITE_DONE else {
            throw sqliteError(db: db)
        }

        let payloadExists = try rowExists(
            db: db,
            sql: "SELECT 1 FROM word_payloads WHERE word_id = ?",
            bind: { stmt in sqlite3_bind_text(stmt, 1, uuid.uuidString, -1, syncTransientDestructor) }
        )

        let payloadSQL: String
        if payloadExists {
            payloadSQL = """
            UPDATE word_payloads
            SET lookup_state_json = ?, lookup_refreshed_at = ?, audio_blob = COALESCE(?, audio_blob), audio_sha256 = ?, ai_artifacts_json = ?, payload_updated_at = ?
            WHERE word_id = ?
            """
        } else {
            payloadSQL = """
            INSERT INTO word_payloads (lookup_state_json, lookup_refreshed_at, audio_blob, audio_sha256, ai_artifacts_json, payload_updated_at, word_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        }

        var payloadStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, payloadSQL, -1, &payloadStmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(payloadStmt) }

        try bindSyncWordPayload(word, audioData: audioData, stmt: payloadStmt)
        guard sqlite3_step(payloadStmt) == SQLITE_DONE else {
            throw sqliteError(db: db)
        }
    }

    private func bindSyncWordCore(_ word: SyncWordRecord, stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, word.collectionId, -1, syncTransientDestructor)
        sqlite3_bind_text(stmt, 2, word.normalizedWord, -1, syncTransientDestructor)
        sqlite3_bind_text(stmt, 3, word.displayWord, -1, syncTransientDestructor)
        bindNullableText(word.sourceForm, stmt: stmt, index: 4)
        bindNullableText(word.inflectionKind, stmt: stmt, index: 5)
        bindNullableText(word.expectedPartOfSpeech, stmt: stmt, index: 6)
        sqlite3_bind_double(stmt, 7, word.createdAt)
        sqlite3_bind_double(stmt, 8, word.updatedAt)
        if let deletedAt = word.deletedAt {
            sqlite3_bind_double(stmt, 9, deletedAt)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        sqlite3_bind_text(stmt, 10, word.id, -1, syncTransientDestructor)
    }

    private func bindSyncWordPayload(_ word: SyncWordRecord, audioData: Data?, stmt: OpaquePointer?) throws {
        let lookupStateData = word.payload.lookupStateBase64.flatMap { Data(base64Encoded: $0) }
        if let lookupStateData {
            _ = lookupStateData.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, 1, buffer.baseAddress, Int32(buffer.count), syncTransientDestructor)
            }
        } else {
            sqlite3_bind_null(stmt, 1)
        }

        if let lookupRefreshedAt = word.payload.lookupRefreshedAt {
            sqlite3_bind_double(stmt, 2, lookupRefreshedAt)
        } else {
            sqlite3_bind_null(stmt, 2)
        }

        if let audioData {
            _ = audioData.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, 3, buffer.baseAddress, Int32(buffer.count), syncTransientDestructor)
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        bindNullableText(word.payload.audioRef, stmt: stmt, index: 4)
        bindNullableText(word.payload.aiArtifactsJSON, stmt: stmt, index: 5)
        sqlite3_bind_double(stmt, 6, word.payload.payloadUpdatedAt)
        sqlite3_bind_text(stmt, 7, word.id, -1, syncTransientDestructor)
    }
}

private let syncTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
