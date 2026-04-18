import Foundation
import CommonCrypto
import SQLite3

public enum AnkiSQLiteError: Error, Sendable {
    case cannotOpenDatabase(String)
    case sqlError(String)
}

public enum AnkiSQLiteWriter {
    /// Creates a collection.anki2 SQLite database at the given path.
    public static func write(
        deck: AnkiDeckConfig,
        notes: [AnkiNoteData],
        to path: String
    ) throws {
        try write(
            decks: [
                AnkiDeckPayload(deck: deck, notes: notes)
            ],
            to: path
        )
    }

    public static func write(
        decks: [AnkiDeckPayload],
        to path: String
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw AnkiSQLiteError.cannotOpenDatabase(msg)
        }
        defer { sqlite3_close(db) }

        try exec(db: db, sql: createTableSQL)
        try insertCollectionRow(db: db, decks: decks.map(\.deck))
        try insertNotes(db: db, decks: decks)
    }

    // MARK: - Schema

    private static let createTableSQL = """
    CREATE TABLE col (
        id INTEGER PRIMARY KEY,
        crt INTEGER NOT NULL,
        mod INTEGER NOT NULL,
        scm INTEGER NOT NULL,
        ver INTEGER NOT NULL,
        dty INTEGER NOT NULL,
        usn INTEGER NOT NULL,
        ls INTEGER NOT NULL,
        conf TEXT NOT NULL,
        models TEXT NOT NULL,
        decks TEXT NOT NULL,
        dconf TEXT NOT NULL,
        tags TEXT NOT NULL
    );
    CREATE TABLE notes (
        id INTEGER PRIMARY KEY,
        guid TEXT NOT NULL,
        mid INTEGER NOT NULL,
        mod INTEGER NOT NULL,
        usn INTEGER NOT NULL,
        tags TEXT NOT NULL,
        flds TEXT NOT NULL,
        sfld TEXT NOT NULL,
        csum INTEGER NOT NULL,
        flags INTEGER NOT NULL,
        data TEXT NOT NULL
    );
    CREATE TABLE cards (
        id INTEGER PRIMARY KEY,
        nid INTEGER NOT NULL,
        did INTEGER NOT NULL,
        ord INTEGER NOT NULL,
        mod INTEGER NOT NULL,
        usn INTEGER NOT NULL,
        type INTEGER NOT NULL,
        queue INTEGER NOT NULL,
        due INTEGER NOT NULL,
        ivl INTEGER NOT NULL,
        factor INTEGER NOT NULL,
        reps INTEGER NOT NULL,
        lapses INTEGER NOT NULL,
        left INTEGER NOT NULL,
        odue INTEGER NOT NULL,
        odid INTEGER NOT NULL,
        flags INTEGER NOT NULL,
        data TEXT NOT NULL
    );
    CREATE TABLE revlog (
        id INTEGER PRIMARY KEY,
        cid INTEGER NOT NULL,
        usn INTEGER NOT NULL,
        ease INTEGER NOT NULL,
        ivl INTEGER NOT NULL,
        lastIvl INTEGER NOT NULL,
        factor INTEGER NOT NULL,
        time INTEGER NOT NULL,
        type INTEGER NOT NULL
    );
    CREATE TABLE graves (
        usn INTEGER NOT NULL,
        oid INTEGER NOT NULL,
        type INTEGER NOT NULL
    );
    """

    // MARK: - Collection Row

    private static func insertCollectionRow(db: OpaquePointer?, decks: [AnkiDeckConfig]) throws {
        let primaryDeck = decks.first ?? AnkiDeckConfig(deckName: "Anki Mate Vocabulary")
        let now = Int64(Date().timeIntervalSince1970)
        let nowMs = now * 1000

        let activeDecks = decks.map(\.deckId).map(String.init).joined(separator: ",")
        let conf = """
        {"activeDecks":[\(activeDecks)],"curDeck":\(primaryDeck.deckId),"newSpread":0,"collapseTime":1200,"timeLim":0,"estTimes":true,"dueCounts":true,"curModel":\(primaryDeck.modelId),"nextPos":1,"sortType":"noteFld","sortBackwards":false,"addToCur":true}
        """

        let fields = AnkiCardTemplate.fields.enumerated().map { i, name in
            "{\"name\":\"\(name)\",\"ord\":\(i),\"sticky\":false,\"rtl\":false,\"font\":\"Arial\",\"size\":20,\"media\":[]}"
        }.joined(separator: ",")

        let tmpls = """
        [{"name":"Card 1","ord":0,"qfmt":\(jsonString(AnkiCardTemplate.frontTemplate)),"afmt":\(jsonString(AnkiCardTemplate.backTemplate)),"did":null,"bqfmt":"","bafmt":""}]
        """

        let model = """
        {"\(primaryDeck.modelId)":{"id":\(primaryDeck.modelId),"name":"\(AnkiCardTemplate.modelName)","type":0,"mod":\(now),"usn":-1,"sortf":0,"did":\(primaryDeck.deckId),"tmpls":\(tmpls),"flds":[\(fields)],"css":\(jsonString(AnkiCardTemplate.css)),"latexPre":"","latexPost":"","latexsvg":false,"req":[[0,"all",[0]]],"vers":[],"tags":[]}}
        """

        let deckObjects = decks.map {
            "\"\($0.deckId)\":{\"id\":\($0.deckId),\"name\":\(jsonString($0.deckName)),\"mod\":\(now),\"usn\":-1,\"lrnToday\":[0,0],\"revToday\":[0,0],\"newToday\":[0,0],\"timeToday\":[0,0],\"collapsed\":false,\"desc\":\(jsonString($0.deckDescription)),\"dyn\":0,\"conf\":1,\"extendNew\":10,\"extendRev\":50}"
        }.joined(separator: ",")
        let decksJSON = "{\"1\":{\"id\":1,\"name\":\"Default\",\"mod\":\(now),\"usn\":-1,\"lrnToday\":[0,0],\"revToday\":[0,0],\"newToday\":[0,0],\"timeToday\":[0,0],\"collapsed\":false,\"desc\":\"\",\"dyn\":0,\"conf\":1,\"extendNew\":10,\"extendRev\":50},\(deckObjects)}"

        let dconf = """
        {"1":{"id":1,"mod":\(now),"usn":-1,"name":"Default","replayq":true,"lapse":{"delays":[10],"mult":0,"minInt":1,"leechFails":8,"leechAction":0},"rev":{"perDay":200,"ease4":1.3,"fuzz":0.05,"minSpace":1,"ivlFct":1,"maxIvl":36500,"bury":false,"hardFactor":1.2},"new":{"delays":[1,10],"ints":[1,4,0],"initialFactor":2500,"order":1,"perDay":20,"bury":false},"maxTaken":60,"timer":0,"autoplay":true}}
        """

        let sql = "INSERT INTO col VALUES (1, ?, ?, ?, 11, 0, -1, 0, ?, ?, ?, ?, '{}')"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, now)
        sqlite3_bind_int64(stmt, 2, now)
        sqlite3_bind_int64(stmt, 3, nowMs)
        sqlite3_bind_text(stmt, 4, conf, -1, transient)
        sqlite3_bind_text(stmt, 5, model, -1, transient)
        sqlite3_bind_text(stmt, 6, decksJSON, -1, transient)
        sqlite3_bind_text(stmt, 7, dconf, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw sqliteError(db: db)
        }
    }

    // MARK: - Notes & Cards

    private static func insertNotes(db: OpaquePointer?, decks: [AnkiDeckPayload]) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let modelId = decks.first?.deck.modelId ?? AnkiDeckConfig(deckName: "Anki Mate Vocabulary").modelId

        let noteSQL = "INSERT INTO notes VALUES (?, ?, ?, ?, -1, '', ?, ?, ?, 0, '')"
        let cardSQL = "INSERT INTO cards VALUES (?, ?, ?, 0, ?, -1, 0, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, '')"

        var noteStmt: OpaquePointer?
        var cardStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, noteSQL, -1, &noteStmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(noteStmt) }

        guard sqlite3_prepare_v2(db, cardSQL, -1, &cardStmt, nil) == SQLITE_OK else {
            throw sqliteError(db: db)
        }
        defer { sqlite3_finalize(cardStmt) }

        var noteIndex = 0
        for payload in decks {
            for note in payload.notes {
                let noteId = now * 1000 + Int64(noteIndex)
                let cardId = noteId + 1_000_000
                let guid = stableAnkiGUID(seed: note.guidSeed)
                let flds = note.fieldsString
                let sfld = note.sortField
                let csum = fieldChecksum(sfld)

                sqlite3_reset(noteStmt)
                sqlite3_bind_int64(noteStmt, 1, noteId)
                sqlite3_bind_text(noteStmt, 2, guid, -1, transient)
                sqlite3_bind_int64(noteStmt, 3, modelId)
                sqlite3_bind_int64(noteStmt, 4, now)
                sqlite3_bind_text(noteStmt, 5, flds, -1, transient)
                sqlite3_bind_text(noteStmt, 6, sfld, -1, transient)
                sqlite3_bind_int64(noteStmt, 7, csum)

                guard sqlite3_step(noteStmt) == SQLITE_DONE else {
                    throw sqliteError(db: db)
                }

                sqlite3_reset(cardStmt)
                sqlite3_bind_int64(cardStmt, 1, cardId)
                sqlite3_bind_int64(cardStmt, 2, noteId)
                sqlite3_bind_int64(cardStmt, 3, payload.deck.deckId)
                sqlite3_bind_int64(cardStmt, 4, now)
                sqlite3_bind_int64(cardStmt, 5, Int64(noteIndex))

                guard sqlite3_step(cardStmt) == SQLITE_DONE else {
                    throw sqliteError(db: db)
                }
                noteIndex += 1
            }
        }
    }

    // MARK: - Helpers

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw AnkiSQLiteError.sqlError(msg)
        }
    }

    private static func sqliteError(db: OpaquePointer?) -> AnkiSQLiteError {
        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .sqlError(msg)
    }

    static func stableAnkiGUID(seed: String) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&()*+,-./:;<=>?@[]^_`{|}~")
        let data = Array(seed.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(data, CC_LONG(data.count), &hash)

        var guid = ""
        guid.reserveCapacity(10)
        for index in 0..<10 {
            let first = Int(hash[(index * 2) % hash.count])
            let second = Int(hash[(index * 2 + 1) % hash.count])
            let combined = (first << 8) | second
            // Anki GUIDs are short strings over a restricted character set, so we
            // deterministically project the SHA1 bytes into that alphabet instead
            // of storing a raw hex digest.
            guid.append(chars[combined % chars.count])
        }
        return guid
    }

    static func fieldChecksum(_ field: String) -> Int64 {
        let data = Array(field.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(data, CC_LONG(data.count), &hash)
        let hex = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        return Int64(hex, radix: 16) ?? 0
    }

    private static func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
