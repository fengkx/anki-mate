import DictKit
import DictKitSystemDictionary
import Foundation
import SQLite3

enum WordListStoreError: Error, LocalizedError {
    case cannotOpenDatabase(String)
    case validationFailed(String)
    case duplicateWord(String)
    case duplicateCollection(String)
    case sqlError(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let message):
            return "Cannot open word list database: \(message)"
        case .validationFailed(let message):
            return "Invalid word list data: \(message)"
        case .duplicateWord(let word):
            return "Duplicate word in collection: \(word)"
        case .duplicateCollection(let name):
            return "Duplicate collection: \(name)"
        case .sqlError(let message):
            return "SQLite error: \(message)"
        }
    }
}

protocol WordListStoring {
    func loadCollections() throws -> [PersistedCollectionRecord]
    func createCollection(name: String, exportSettings: CollectionExportSettings, dictionaryName: String) throws -> PersistedCollectionRecord
    func renameCollection(id: UUID, name: String, exportSettings: CollectionExportSettings, dictionaryName: String) throws -> PersistedCollectionRecord
    func deleteCollection(id: UUID) throws
    func loadWords(in collectionID: UUID) throws -> [PersistedWordRecord]
    func loadAllWords() throws -> [PersistedWordRecord]
    func upsertWord(_ record: PersistedWordRecord, into collectionID: UUID) throws -> PersistedWordUpsertResult
    func saveWord(_ record: PersistedWordRecord) throws
    func removeWord(id: UUID, from collectionID: UUID) throws
}

extension WordListStoring {
    func createCollection(name: String, exportSettings: CollectionExportSettings) throws -> PersistedCollectionRecord {
        try createCollection(name: name, exportSettings: exportSettings, dictionaryName: "")
    }

    func renameCollection(id: UUID, name: String, exportSettings: CollectionExportSettings) throws -> PersistedCollectionRecord {
        try renameCollection(id: id, name: name, exportSettings: exportSettings, dictionaryName: "")
    }

    func createCollection(name: String, deckName: String?) throws -> PersistedCollectionRecord {
        try createCollection(
            name: name,
            exportSettings: CollectionExportSettings(
                deckName: deckName ?? name,
                deckDescription: ""
            ),
            dictionaryName: ""
        )
    }

    func renameCollection(id: UUID, name: String, deckName: String?) throws -> PersistedCollectionRecord {
        try renameCollection(
            id: id,
            name: name,
            exportSettings: CollectionExportSettings(
                deckName: deckName ?? name,
                deckDescription: ""
            ),
            dictionaryName: ""
        )
    }
}

struct CollectionExportSettings: Equatable, Sendable {
    let deckName: String
    let deckDescription: String

    init(deckName: String, deckDescription: String) {
        self.deckName = deckName
        self.deckDescription = deckDescription
    }

    static func defaults(forCollectionName name: String) -> CollectionExportSettings {
        CollectionExportSettings(deckName: name, deckDescription: "")
    }
}

struct PersistedCollectionRecord: Identifiable, Equatable {
    let id: UUID
    let name: String
    let dictionaryName: String
    let exportSettings: CollectionExportSettings
    let createdAt: Date
    let updatedAt: Date

    init(id: UUID, name: String, dictionaryName: String, exportSettings: CollectionExportSettings, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.dictionaryName = dictionaryName
        self.exportSettings = exportSettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(id: UUID, name: String, dictionaryName: String, ankiDeckName: String, createdAt: Date, updatedAt: Date) {
        self.init(
            id: id,
            name: name,
            dictionaryName: dictionaryName,
            exportSettings: .init(deckName: ankiDeckName, deckDescription: ""),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var ankiDeckName: String {
        exportSettings.deckName
    }

    var ankiDeckDescription: String {
        exportSettings.deckDescription
    }

    init(id: UUID, name: String, exportSettings: CollectionExportSettings, createdAt: Date, updatedAt: Date) {
        self.init(
            id: id,
            name: name,
            dictionaryName: "",
            exportSettings: exportSettings,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct PersistedWordUpsertResult: Equatable {
    let record: PersistedWordRecord
    let insertedWord: Bool
    let insertedAssociation: Bool
}

struct PersistedWordRecord: Equatable {
    let id: UUID
    let displayWord: String
    let normalizedWord: String
    let sourceForm: String?
    let inflectionKind: InflectionKind?
    let expectedPartOfSpeech: PartOfSpeech?
    let lookupState: PersistedLookupState
    let audioData: Data?
    let createdAt: Date
    let updatedAt: Date
    let lastRefreshedAt: Date?

    init(
        id: UUID,
        displayWord: String,
        normalizedWord: String,
        sourceForm: String? = nil,
        inflectionKind: InflectionKind? = nil,
        expectedPartOfSpeech: PartOfSpeech? = nil,
        lookupState: PersistedLookupState,
        audioData: Data?,
        createdAt: Date,
        updatedAt: Date,
        lastRefreshedAt: Date?
    ) {
        self.id = id
        self.displayWord = displayWord
        self.normalizedWord = normalizedWord
        self.sourceForm = sourceForm
        self.inflectionKind = inflectionKind
        self.expectedPartOfSpeech = expectedPartOfSpeech
        self.lookupState = lookupState
        self.audioData = audioData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRefreshedAt = lastRefreshedAt
    }
}

enum PersistedLookupState: Codable, Equatable {
    case pending
    case loading
    case loaded(LookupResult)
    case failed(String)
}

struct WordListStore: WordListStoring {
    private static let schemaVersion = 6

    let databaseURL: URL

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try withDatabase { db in
            try Self.exec(db: db, sql: "PRAGMA foreign_keys = ON;")
            try Self.migrateIfNeeded(db: db)
            try Self.ensureDefaultCollection(db: db)
        }
    }

    static func normalizedWord(for word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func loadCollections() throws -> [PersistedCollectionRecord] {
        try withDatabase { db in
            let sql = """
            SELECT id, name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at
            FROM collections
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            var records: [PersistedCollectionRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(
                    PersistedCollectionRecord(
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
                )
            }
            return records
        }
    }

    func createCollection(name: String, exportSettings: CollectionExportSettings, dictionaryName: String) throws -> PersistedCollectionRecord {
        let validatedName = try validatedCollectionName(name)
        let now = Date()
        let record = PersistedCollectionRecord(
            id: UUID(),
            name: validatedName,
            dictionaryName: validatedDictionaryName(dictionaryName),
            exportSettings: try validatedExportSettings(exportSettings, fallbackName: validatedName),
            createdAt: now,
            updatedAt: now
        )

        try withDatabase { db in
            let sql = """
            INSERT INTO collections (id, name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            bindCollection(record, stmt: stmt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                if sqlite3_errcode(db) == SQLITE_CONSTRAINT {
                    throw WordListStoreError.duplicateCollection(record.name)
                }
                throw sqliteError(db: db)
            }
        }

        return record
    }

    func renameCollection(id: UUID, name: String, exportSettings: CollectionExportSettings, dictionaryName: String) throws -> PersistedCollectionRecord {
        let existing = try collection(id: id)
        let validatedName = try validatedCollectionName(name)
        let record = PersistedCollectionRecord(
            id: id,
            name: validatedName,
            dictionaryName: validatedDictionaryName(dictionaryName),
            exportSettings: try validatedExportSettings(exportSettings, fallbackName: validatedName),
            createdAt: existing.createdAt,
            updatedAt: Date()
        )

        try withDatabase { db in
            let sql = """
            UPDATE collections
            SET name = ?, dictionary_name = ?, anki_deck_name = ?, deck_description = ?, updated_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, record.name, -1, transientDestructor)
            sqlite3_bind_text(stmt, 2, record.dictionaryName, -1, transientDestructor)
            sqlite3_bind_text(stmt, 3, record.ankiDeckName, -1, transientDestructor)
            sqlite3_bind_text(stmt, 4, record.ankiDeckDescription, -1, transientDestructor)
            sqlite3_bind_double(stmt, 5, record.updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 6, id.uuidString, -1, transientDestructor)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                if sqlite3_errcode(db) == SQLITE_CONSTRAINT {
                    throw WordListStoreError.duplicateCollection(record.name)
                }
                throw sqliteError(db: db)
            }
        }

        return record
    }

    func deleteCollection(id: UUID) throws {
        let collections = try loadCollections()
        guard collections.count > 1 else {
            throw WordListStoreError.validationFailed("at least one collection must remain")
        }

        try withDatabase { db in
            let sql = "DELETE FROM collections WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, id.uuidString, -1, transientDestructor)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    func loadWords(in collectionID: UUID) throws -> [PersistedWordRecord] {
        _ = try collection(id: collectionID)
        return try withDatabase { db in
            let sql = """
            SELECT id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at
            FROM words
            WHERE collection_id = ?
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, collectionID.uuidString, -1, transientDestructor)
            return try readWords(from: stmt)
        }
    }

    func loadAllWords() throws -> [PersistedWordRecord] {
        try withDatabase { db in
            let sql = """
            SELECT id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at
            FROM words
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            return try readWords(from: stmt)
        }
    }

    func upsertWord(_ record: PersistedWordRecord, into collectionID: UUID) throws -> PersistedWordUpsertResult {
        try validateWord(record)
        _ = try collection(id: collectionID)

        return try withDatabase { db in
            if try existingWord(normalizedWord: record.normalizedWord, collectionID: collectionID, db: db) != nil {
                throw WordListStoreError.duplicateWord(record.displayWord)
            }

            let sql = """
            INSERT INTO words (
              id, collection_id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            try bindAndInsertWord(record, collectionID: collectionID, db: db, sql: sql)
            return PersistedWordUpsertResult(record: record, insertedWord: true, insertedAssociation: false)
        }
    }

    func saveWord(_ record: PersistedWordRecord) throws {
        try validateWord(record)
        try withDatabase { db in
            let sql = """
            UPDATE words
            SET normalized_word = ?, display_word = ?, source_form = ?, inflection_kind = ?, expected_part_of_speech = ?, lookup_state_json = ?, audio_data = ?, created_at = ?, updated_at = ?, last_refreshed_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            try bindWordFields(record, stmt: stmt, startIndex: 1)
            sqlite3_bind_text(stmt, 11, record.id.uuidString, -1, transientDestructor)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    func removeWord(id: UUID, from collectionID: UUID) throws {
        try withDatabase { db in
            let sql = "DELETE FROM words WHERE collection_id = ? AND id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw sqliteError(db: db)
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, collectionID.uuidString, -1, transientDestructor)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, transientDestructor)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db)
            }
        }
    }

    private func collection(id: UUID) throws -> PersistedCollectionRecord {
        let collections = try loadCollections()
        guard let record = collections.first(where: { $0.id == id }) else {
            throw WordListStoreError.validationFailed("missing collection")
        }
        return record
    }

    private func validatedCollectionName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WordListStoreError.validationFailed("Collection name must not be empty")
        }
        return trimmed
    }

    private func validatedDeckName(_ deckName: String?, fallback: String) throws -> String {
        let trimmed = deckName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return try validatedCollectionName(fallback)
    }

    private func validatedDeckDescription(_ description: String) -> String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validatedDictionaryName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validatedExportSettings(
        _ settings: CollectionExportSettings,
        fallbackName: String
    ) throws -> CollectionExportSettings {
        CollectionExportSettings(
            deckName: try validatedDeckName(settings.deckName, fallback: fallbackName),
            deckDescription: validatedDeckDescription(settings.deckDescription)
        )
    }

    private func validateWord(_ record: PersistedWordRecord) throws {
        let trimmed = record.displayWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WordListStoreError.validationFailed("display_word must not be empty")
        }
        guard record.normalizedWord == Self.normalizedWord(for: record.displayWord) else {
            throw WordListStoreError.validationFailed("normalized_word does not match display_word")
        }
        if let sourceForm = record.sourceForm,
           sourceForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WordListStoreError.validationFailed("source_form must not be empty when present")
        }
        if case .failed(let message) = record.lookupState,
           message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WordListStoreError.validationFailed("failed lookup state requires an error message")
        }
        guard record.audioData?.isEmpty != true else {
            throw WordListStoreError.validationFailed("audio_data must not be empty when present")
        }
        guard record.createdAt <= record.updatedAt else {
            throw WordListStoreError.validationFailed("created_at must not be later than updated_at")
        }
        if let lastRefreshedAt = record.lastRefreshedAt, lastRefreshedAt < record.createdAt {
            throw WordListStoreError.validationFailed("last_refreshed_at must not be earlier than created_at")
        }
        let encodedState = try JSONEncoder().encode(record.lookupState)
        _ = try JSONDecoder().decode(PersistedLookupState.self, from: encodedState)
    }

    private func existingWord(normalizedWord: String, collectionID: UUID, db: OpaquePointer?) throws -> PersistedWordRecord? {
        let sql = """
        SELECT id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at
        FROM words
        WHERE collection_id = ? AND normalized_word = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, collectionID.uuidString, -1, transientDestructor)
        sqlite3_bind_text(stmt, 2, normalizedWord, -1, transientDestructor)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return try readWord(from: stmt)
    }

    private func bindAndInsertWord(_ record: PersistedWordRecord, collectionID: UUID, db: OpaquePointer?, sql: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, transientDestructor)
        sqlite3_bind_text(stmt, 2, collectionID.uuidString, -1, transientDestructor)
        try bindWordFields(record, stmt: stmt, startIndex: 3)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            if sqlite3_errcode(db) == SQLITE_CONSTRAINT {
                throw WordListStoreError.duplicateWord(record.displayWord)
            }
            throw sqliteError(db: db)
        }
    }

    private func bindCollection(_ record: PersistedCollectionRecord, stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, transientDestructor)
        sqlite3_bind_text(stmt, 2, record.name, -1, transientDestructor)
        sqlite3_bind_text(stmt, 3, record.dictionaryName, -1, transientDestructor)
        sqlite3_bind_text(stmt, 4, record.ankiDeckName, -1, transientDestructor)
        sqlite3_bind_text(stmt, 5, record.ankiDeckDescription, -1, transientDestructor)
        sqlite3_bind_double(stmt, 6, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, record.updatedAt.timeIntervalSince1970)
    }

    private func bindWordFields(_ record: PersistedWordRecord, stmt: OpaquePointer?, startIndex: Int32) throws {
        let lookupStateData = try JSONEncoder().encode(record.lookupState)

        sqlite3_bind_text(stmt, startIndex + 0, record.normalizedWord, -1, transientDestructor)
        sqlite3_bind_text(stmt, startIndex + 1, record.displayWord, -1, transientDestructor)
        if let sourceForm = record.sourceForm {
            sqlite3_bind_text(stmt, startIndex + 2, sourceForm, -1, transientDestructor)
        } else {
            sqlite3_bind_null(stmt, startIndex + 2)
        }
        if let inflectionKind = record.inflectionKind {
            sqlite3_bind_text(stmt, startIndex + 3, inflectionKind.rawValue, -1, transientDestructor)
        } else {
            sqlite3_bind_null(stmt, startIndex + 3)
        }
        if let expectedPartOfSpeech = record.expectedPartOfSpeech {
            sqlite3_bind_text(stmt, startIndex + 4, expectedPartOfSpeech.rawValue, -1, transientDestructor)
        } else {
            sqlite3_bind_null(stmt, startIndex + 4)
        }
        _ = lookupStateData.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, startIndex + 5, buffer.baseAddress, Int32(buffer.count), transientDestructor)
        }
        if let audioData = record.audioData {
            _ = audioData.withUnsafeBytes { buffer in
                sqlite3_bind_blob(stmt, startIndex + 6, buffer.baseAddress, Int32(buffer.count), transientDestructor)
            }
        } else {
            sqlite3_bind_null(stmt, startIndex + 6)
        }
        sqlite3_bind_double(stmt, startIndex + 7, record.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, startIndex + 8, record.updatedAt.timeIntervalSince1970)
        if let lastRefreshedAt = record.lastRefreshedAt {
            sqlite3_bind_double(stmt, startIndex + 9, lastRefreshedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, startIndex + 9)
        }
    }

    private func readWords(from stmt: OpaquePointer?) throws -> [PersistedWordRecord] {
        var records: [PersistedWordRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(try readWord(from: stmt))
        }
        return records
    }

    private func readWord(from stmt: OpaquePointer?) throws -> PersistedWordRecord {
        let record = PersistedWordRecord(
            id: try uuidColumn(stmt, index: 0),
            displayWord: try textColumn(stmt, index: 2),
            normalizedWord: try textColumn(stmt, index: 1),
            sourceForm: nullableTextColumn(stmt, index: 3),
            inflectionKind: nullableTextColumn(stmt, index: 4).flatMap(InflectionKind.init(rawValue:)),
            expectedPartOfSpeech: nullableTextColumn(stmt, index: 5).flatMap(PartOfSpeech.init(rawValue:)),
            lookupState: try decodeLookupState(blobColumn(stmt, index: 6)),
            audioData: blobColumn(stmt, index: 7),
            createdAt: dateColumn(stmt, index: 8),
            updatedAt: dateColumn(stmt, index: 9),
            lastRefreshedAt: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : dateColumn(stmt, index: 10)
        )
        try validateWord(record)
        return record
    }

    private static func ensureDefaultCollection(db: OpaquePointer?) throws {
        let sql = "SELECT COUNT(*) FROM collections"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WordListStoreError.sqlError("cannot prepare default collection count query")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WordListStoreError.sqlError("cannot read default collection count")
        }

        guard sqlite3_column_int64(stmt, 0) == 0 else { return }

        let now = Date().timeIntervalSince1970
        let collectionID = UUID().uuidString
        try exec(
            db: db,
            sql: """
            INSERT INTO collections (id, name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at)
            VALUES ('\(collectionID)', 'Default', '', 'Default', '', \(now), \(now))
            """
        )
    }

    private static func currentSchemaVersion(db: OpaquePointer?) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw WordListStoreError.sqlError("cannot read schema version")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WordListStoreError.sqlError("cannot step schema version")
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private static func setSchemaVersion(_ version: Int, db: OpaquePointer?) throws {
        try exec(db: db, sql: "PRAGMA user_version = \(version);")
    }

    private static func migrateIfNeeded(db: OpaquePointer?) throws {
        let version = try currentSchemaVersion(db: db)
        switch version {
        case schemaVersion:
            return
        case 5:
            try migrateFromVersion5(db: db)
            try setSchemaVersion(schemaVersion, db: db)
        default:
            try rebuildSchema(db: db)
            try setSchemaVersion(schemaVersion, db: db)
        }
    }

    private static func rebuildSchema(db: OpaquePointer?) throws {
        try exec(
            db: db,
            sql: """
            PRAGMA foreign_keys = OFF;
            DROP TABLE IF EXISTS collection_words;
            DROP TABLE IF EXISTS collections;
            DROP TABLE IF EXISTS words;

            CREATE TABLE collections (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL COLLATE NOCASE UNIQUE,
              dictionary_name TEXT NOT NULL,
              anki_deck_name TEXT NOT NULL,
              deck_description TEXT NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );

            CREATE TABLE words (
              id TEXT PRIMARY KEY,
              collection_id TEXT NOT NULL,
              normalized_word TEXT NOT NULL,
              display_word TEXT NOT NULL,
              source_form TEXT,
              inflection_kind TEXT,
              expected_part_of_speech TEXT,
              lookup_state_json BLOB,
              audio_data BLOB,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              last_refreshed_at REAL,
              UNIQUE (collection_id, normalized_word),
              FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE
            );
            PRAGMA foreign_keys = ON;
            """
        )
    }

    private func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw WordListStoreError.cannotOpenDatabase(message)
        }
        defer { sqlite3_close(db) }
        try Self.exec(db: db, sql: "PRAGMA foreign_keys = ON;")
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

    private func blobColumn(_ stmt: OpaquePointer?, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    private func dateColumn(_ stmt: OpaquePointer?, index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    private func decodeLookupState(_ data: Data?) throws -> PersistedLookupState {
        guard let data else { return .pending }
        return try JSONDecoder().decode(PersistedLookupState.self, from: data)
    }

    private func sqliteError(db: OpaquePointer?) -> WordListStoreError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .sqlError(message)
    }

    private static func migrateFromVersion5(db: OpaquePointer?) throws {
        try exec(db: db, sql: "ALTER TABLE words ADD COLUMN source_form TEXT;")
        try exec(db: db, sql: "ALTER TABLE words ADD COLUMN inflection_kind TEXT;")
        try exec(db: db, sql: "ALTER TABLE words ADD COLUMN expected_part_of_speech TEXT;")
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw WordListStoreError.sqlError(message)
        }
    }
}

struct NoOpWordListStore: WordListStoring {
    func loadCollections() throws -> [PersistedCollectionRecord] { [] }
    func createCollection(name: String, exportSettings: CollectionExportSettings, dictionaryName: String) throws -> PersistedCollectionRecord {
        let now = Date()
        return PersistedCollectionRecord(id: UUID(), name: name, dictionaryName: dictionaryName, exportSettings: exportSettings, createdAt: now, updatedAt: now)
    }
    func renameCollection(id: UUID, name: String, exportSettings: CollectionExportSettings, dictionaryName: String) throws -> PersistedCollectionRecord {
        let now = Date()
        return PersistedCollectionRecord(id: id, name: name, dictionaryName: dictionaryName, exportSettings: exportSettings, createdAt: now, updatedAt: now)
    }
    func deleteCollection(id: UUID) throws {}
    func loadWords(in collectionID: UUID) throws -> [PersistedWordRecord] { [] }
    func loadAllWords() throws -> [PersistedWordRecord] { [] }
    func upsertWord(_ record: PersistedWordRecord, into collectionID: UUID) throws -> PersistedWordUpsertResult {
        PersistedWordUpsertResult(record: record, insertedWord: true, insertedAssociation: true)
    }
    func saveWord(_ record: PersistedWordRecord) throws {}
    func removeWord(id: UUID, from collectionID: UUID) throws {}
}

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
