import CryptoKit
import Foundation

/// Handles content-addressed audio file operations on WebDAV.
enum SyncAudioStore {

    /// Compute the remote path for an audio hash.
    static func remotePath(for hash: String) -> String {
        let prefix = String(hash.prefix(2))
        return "anki-mate/audio/\(prefix)/\(hash).wav"
    }

    /// SHA-256 hex hash of audio data.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Upload audio data if it doesn't already exist on remote.
    static func upload(hash: String, data: Data, client: any WebDAVClientProtocol) async throws {
        let path = remotePath(for: hash)
        // Check if already exists (avoid re-upload)
        if try await client.exists(path) { return }
        // Ensure prefix directory exists
        let prefix = String(hash.prefix(2))
        try await client.mkcol("anki-mate/audio/\(prefix)/")
        // Upload
        try await client.put(path, data: data, contentType: "audio/wav")
    }

    /// Download audio data by hash. Returns nil if not found.
    static func download(hash: String, client: any WebDAVClientProtocol) async throws -> Data? {
        let path = remotePath(for: hash)
        guard let data = try await client.get(path) else { return nil }
        // Verify integrity
        let computed = self.hash(data)
        guard computed == hash else {
            // Corruption — re-download or return nil
            return nil
        }
        return data
    }
}
