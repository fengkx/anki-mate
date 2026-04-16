import Foundation

public enum AnkiPackageError: Error, Sendable {
    case zipFailed(String)
    case fileWriteError(String)
}

public enum AnkiPackageWriter {
    /// Assembles a complete .apkg file at the given URL.
    /// An .apkg is a zip archive containing:
    /// - collection.anki2 (SQLite database)
    /// - media (JSON mapping of numeric filenames to real names)
    /// - 0, 1, 2... (media files with numeric names)
    public static func write(
        deck: AnkiDeckConfig,
        notes: [AnkiNoteData],
        to outputURL: URL
    ) throws {
        try write(
            decks: [
                AnkiDeckPayload(deck: deck, notes: notes)
            ],
            to: outputURL
        )
    }

    public static func write(
        decks: [AnkiDeckPayload],
        to outputURL: URL
    ) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // 1. Create SQLite database
        let dbPath = tempDir.appendingPathComponent("collection.anki2").path
        try AnkiSQLiteWriter.write(decks: decks, to: dbPath)

        // 2. Write media files with numeric names and build media map
        var mediaMap: [String: String] = [:]
        var mediaIndex = 0
        var writtenFilenames = Set<String>()
        for note in decks.flatMap(\.notes) {
            guard let audioData = note.audioData, let filename = note.audioFilename else { continue }
            guard writtenFilenames.insert(filename).inserted else { continue }
            let numericName = "\(mediaIndex)"
            try audioData.write(to: tempDir.appendingPathComponent(numericName))
            mediaMap[numericName] = filename
            mediaIndex += 1
        }

        // 3. Write media JSON
        let mediaJSON = try JSONSerialization.data(
            withJSONObject: mediaMap,
            options: [.sortedKeys]
        )
        try mediaJSON.write(to: tempDir.appendingPathComponent("media"))

        // 4. Zip into .apkg
        // Remove existing file if present
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--norsrc",
            tempDir.path, outputURL.path
        ]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw AnkiPackageError.zipFailed(errMsg)
        }
    }
}
