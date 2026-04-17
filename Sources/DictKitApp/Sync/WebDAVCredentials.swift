import Foundation
import Security

/// Stores WebDAV credentials (URL, username, password) in the macOS Keychain
/// as a single JSON entry to avoid multiple Keychain prompts.
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

    private static let service = "com.anki-mate.webdav"
    private static let account = "credentials"
    private static let configuredKey = "webdav_configured"

    /// Fast check without touching Keychain.
    static var hasBeenConfigured: Bool {
        UserDefaults.standard.bool(forKey: configuredKey)
    }

    static func load() -> WebDAVCredentials {
        guard hasBeenConfigured else {
            return WebDAVCredentials(serverURL: "", username: "", password: "")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(WebDAVCredentials.self, from: data)
        else {
            return WebDAVCredentials(serverURL: "", username: "", password: "")
        }
        return creds
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
            return
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        if SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: configuredKey)
    }
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
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .networkError(let error): return "Network error: \(error.localizedDescription)"
        case .locked: return "Sync is locked by another device"
        case .notFound: return "Resource not found"
        }
    }
}
