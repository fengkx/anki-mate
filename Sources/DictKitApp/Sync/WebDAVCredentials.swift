import AnkiMateShared
import CryptoKit
import Foundation
import Security

enum WebDAVCredentialStorageMode: Int, CaseIterable, Identifiable, Sendable {
    case keychain
    case encryptedLocalFile

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .keychain:
            return "Use macOS Keychain (Recommended)"
        case .encryptedLocalFile:
            return "Store encrypted locally"
        }
    }

    var summary: String {
        switch self {
        case .keychain:
            return "More secure."
        case .encryptedLocalFile:
            return "Fewer prompts."
        }
    }

    var detail: String {
        switch self {
        case .keychain:
            return "macOS protects your credentials. You may see a system password prompt."
        case .encryptedLocalFile:
            return "Still encrypted on disk, but less secure than Keychain."
        }
    }

    var storedLocationLabel: String {
        switch self {
        case .keychain:
            return "Keychain"
        case .encryptedLocalFile:
            return "Encrypted local storage"
        }
    }
}

struct WebDAVCredentials: Equatable, Sendable, Codable {
    var serverURL: String
    var username: String
    var password: String

    var isConfigured: Bool {
        !serverURL.isEmpty && !username.isEmpty && !password.isEmpty
    }

    var baseURL: URL? {
        URL(string: serverURL)
    }

    // MARK: - Keychain persistence (single entry)

    private static let service = AnkiMateIdentity.webDAVKeychainService
    private static let account = AnkiMateIdentity.webDAVKeychainAccount
    private static let configuredKey = "webdav_configured"
    private static let storageModeKey = "webdav_storage_mode"

    struct KeychainAccess: Sendable {
        var load: @Sendable () -> Data?
        var save: @Sendable (Data) -> Bool
        var delete: @Sendable () -> Void
        var exists: @Sendable () -> Bool
    }

    struct StorageEnvironment: Sendable {
        var userDefaults: @Sendable () -> UserDefaults
        var applicationSupportDirectory: @Sendable () -> URL
        var keychain: KeychainAccess

        static let live = StorageEnvironment(
            userDefaults: { UserDefaults.standard },
            applicationSupportDirectory: {
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                        "Library/Application Support",
                        isDirectory: true
                    )
            },
            keychain: KeychainAccess.live
        )
    }

    static var environment = StorageEnvironment.live

    static var preferredStorageMode: WebDAVCredentialStorageMode {
        let rawValue = defaults.integer(forKey: storageModeKey)
        return WebDAVCredentialStorageMode(rawValue: rawValue) ?? .keychain
    }

    /// Fast check without touching Keychain.
    static var hasBeenConfigured: Bool {
        defaults.bool(forKey: configuredKey) || !storedLocations().isEmpty
    }

    static var currentStorageSummary: String {
        let locations = storedLocations()
        switch locations.count {
        case 0:
            return "Not saved yet"
        case 1:
            return "Saved in \(locations.first?.storedLocationLabel ?? "unknown storage")."
        default:
            let labels = WebDAVCredentialStorageMode.allCases
                .filter { locations.contains($0) }
                .map(\.storedLocationLabel)
                .joined(separator: " and ")
            return "Saved in \(labels)."
        }
    }

    static func load() -> WebDAVCredentials {
        guard hasBeenConfigured else {
            return .empty
        }

        let loadOrder = [preferredStorageMode] + WebDAVCredentialStorageMode.allCases.filter { $0 != preferredStorageMode }
        for mode in loadOrder {
            if let credentials = load(from: mode) {
                return credentials
            }
        }
        return .empty
    }

    @discardableResult
    func save(
        storageMode: WebDAVCredentialStorageMode? = nil,
        autoMigrate: Bool = true
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }

        let targetMode = storageMode ?? Self.preferredStorageMode
        let saveSucceeded: Bool

        switch targetMode {
        case .keychain:
            saveSucceeded = Self.environment.keychain.save(data)
        case .encryptedLocalFile:
            saveSucceeded = Self.saveToEncryptedLocalFile(data)
        }

        guard saveSucceeded else { return false }

        Self.defaults.set(targetMode.rawValue, forKey: Self.storageModeKey)
        Self.defaults.set(true, forKey: Self.configuredKey)

        if autoMigrate {
            WebDAVCredentialStorageMode.allCases
                .filter { $0 != targetMode }
                .forEach(Self.deleteStorage)
        }

        return true
    }

    static func clear() {
        WebDAVCredentialStorageMode.allCases.forEach(deleteStorage)
        defaults.removeObject(forKey: configuredKey)
    }

    static func storedLocations() -> Set<WebDAVCredentialStorageMode> {
        var locations = Set<WebDAVCredentialStorageMode>()
        if environment.keychain.exists() {
            locations.insert(.keychain)
        }
        if encryptedLocalFileExists {
            locations.insert(.encryptedLocalFile)
        }
        return locations
    }
}

private extension WebDAVCredentials {
    static var defaults: UserDefaults {
        environment.userDefaults()
    }

    static var empty: WebDAVCredentials {
        WebDAVCredentials(serverURL: "", username: "", password: "")
    }

    struct EncryptedCredentialEnvelope: Codable {
        let combinedCiphertext: Data
    }

    static func load(from mode: WebDAVCredentialStorageMode) -> WebDAVCredentials? {
        let data: Data?
        switch mode {
        case .keychain:
            data = environment.keychain.load()
        case .encryptedLocalFile:
            data = decryptedLocalCredentialData()
        }

        guard let data,
              let credentials = try? JSONDecoder().decode(WebDAVCredentials.self, from: data)
        else {
            return nil
        }
        return credentials
    }

    static func deleteStorage(_ mode: WebDAVCredentialStorageMode) {
        switch mode {
        case .keychain:
            environment.keychain.delete()
        case .encryptedLocalFile:
            deleteEncryptedLocalFile()
        }
    }

    static var storageDirectoryURL: URL {
        environment.applicationSupportDirectory()
            .appendingPathComponent(AnkiMateIdentity.applicationSupportDirectoryName, isDirectory: true)
    }

    static var encryptedLocalCredentialURL: URL {
        storageDirectoryURL.appendingPathComponent("webdav-credentials.enc")
    }

    static var encryptedLocalKeyURL: URL {
        storageDirectoryURL.appendingPathComponent("webdav-credentials.key")
    }

    static var encryptedLocalFileExists: Bool {
        FileManager.default.fileExists(atPath: encryptedLocalCredentialURL.path)
    }

    static func decryptedLocalCredentialData() -> Data? {
        guard let encryptedPayload = try? Data(contentsOf: encryptedLocalCredentialURL),
              let envelope = try? JSONDecoder().decode(EncryptedCredentialEnvelope.self, from: encryptedPayload),
              let keyData = try? Data(contentsOf: encryptedLocalKeyURL),
              envelope.combinedCiphertext.isEmpty == false
        else {
            return nil
        }

        let key = SymmetricKey(data: keyData)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: envelope.combinedCiphertext),
              let plaintext = try? AES.GCM.open(sealedBox, using: key)
        else {
            return nil
        }

        return plaintext
    }

    static func saveToEncryptedLocalFile(_ credentialData: Data) -> Bool {
        do {
            let key = try loadOrCreateLocalEncryptionKey()
            let sealedBox = try AES.GCM.seal(credentialData, using: key)
            guard let combinedCiphertext = sealedBox.combined else { return false }

            let envelope = EncryptedCredentialEnvelope(combinedCiphertext: combinedCiphertext)
            let payload = try JSONEncoder().encode(envelope)
            try createStorageDirectoryIfNeeded()
            try writeProtectedFile(payload, to: encryptedLocalCredentialURL)
            return true
        } catch {
            return false
        }
    }

    static func deleteEncryptedLocalFile() {
        let manager = FileManager.default
        try? manager.removeItem(at: encryptedLocalCredentialURL)
        try? manager.removeItem(at: encryptedLocalKeyURL)
    }

    static func loadOrCreateLocalEncryptionKey() throws -> SymmetricKey {
        if let existingKeyData = try? Data(contentsOf: encryptedLocalKeyURL) {
            return SymmetricKey(data: existingKeyData)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try createStorageDirectoryIfNeeded()
        try writeProtectedFile(keyData, to: encryptedLocalKeyURL)
        return key
    }

    static func createStorageDirectoryIfNeeded() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: storageDirectoryURL, withIntermediateDirectories: true)
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectoryURL.path)
    }

    static func writeProtectedFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension WebDAVCredentials.KeychainAccess {
    static let live = WebDAVCredentials.KeychainAccess(
        load: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: WebDAVCredentials.service,
                kSecAttrAccount as String: WebDAVCredentials.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess else { return nil }
            return result as? Data
        },
        save: { data in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: WebDAVCredentials.service,
                kSecAttrAccount as String: WebDAVCredentials.account
            ]
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
                return true
            }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        },
        delete: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: WebDAVCredentials.service,
                kSecAttrAccount as String: WebDAVCredentials.account
            ]
            SecItemDelete(query as CFDictionary)
        },
        exists: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: WebDAVCredentials.service,
                kSecAttrAccount as String: WebDAVCredentials.account,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true
            ]
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            return status == errSecSuccess
        }
    )
}

/// User-configurable sync interval, stored in UserDefaults.
enum SyncInterval: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1800
    case oneHour = 3600
    case manual = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .manual: return "Manual"
        }
    }

    private static let key = "sync_interval_seconds"

    static func load() -> SyncInterval {
        let raw = UserDefaults.standard.integer(forKey: key)
        return SyncInterval(rawValue: raw) ?? .tenMinutes
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}

enum WebDAVError: Error, LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case networkError(Error)
    case locked
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid WebDAV URL"
        case .httpError(let code, let msg):
            return "HTTP \(code): \(Self.userFacingHTTPMessage(code: code, body: msg))"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .locked: return "Sync is locked by another device"
        case .notFound: return "Resource not found"
        }
    }

    private static func userFacingHTTPMessage(code: Int, body: String) -> String {
        if code == 401 {
            return "Authentication was rejected. Check the server URL, username, and WebDAV/app password."
        }

        let message = body
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return message.isEmpty ? "Unexpected WebDAV response." : message
    }
}
