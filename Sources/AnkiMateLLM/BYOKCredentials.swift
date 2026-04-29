import AnkiMateShared
import CryptoKit
import Foundation
import Security

public enum LLMBackendMode: String, CaseIterable, Identifiable, Sendable {
    case local
    case openAICompatible

    public var id: String { rawValue }

    public static let defaultsKey = "ankimate.llm.backendMode"

    public static func current(defaults: UserDefaults = .standard) -> LLMBackendMode {
        LLMBackendMode(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .local
    }
}

public enum BYOKCredentialStorageMode: Int, CaseIterable, Identifiable, Sendable {
    case keychain
    case encryptedLocalFile

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .keychain:
            return "Use macOS Keychain (Recommended)"
        case .encryptedLocalFile:
            return "Store encrypted locally"
        }
    }

    public var summary: String {
        switch self {
        case .keychain:
            return "More secure."
        case .encryptedLocalFile:
            return "Fewer prompts."
        }
    }

    public var detail: String {
        switch self {
        case .keychain:
            return "macOS protects your API key. You may see a system password prompt."
        case .encryptedLocalFile:
            return "Still encrypted on disk, but less secure than Keychain."
        }
    }

    public var storedLocationLabel: String {
        switch self {
        case .keychain:
            return "Keychain"
        case .encryptedLocalFile:
            return "encrypted local storage"
        }
    }
}

public struct BYOKCredentials: Equatable, Sendable, Codable {
    public var baseURL: String
    public var modelID: String
    public var apiKey: String

    public init(baseURL: String, modelID: String, apiKey: String) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let baseURLDefaultsKey = "ankimate.byok.baseURL"
    public static let modelIDDefaultsKey = "ankimate.byok.modelID"
    public static let configuredDefaultsKey = "ankimate.byok.configured"
    public static let storageModeDefaultsKey = "ankimate.byok.storageMode"
    public static let lastTestStatusDefaultsKey = "ankimate.byok.lastTestStatus"

    public struct DataStore: Sendable {
        public var load: @Sendable () -> Data?
        public var save: @Sendable (Data) -> Bool
        public var delete: @Sendable () -> Void
        public var exists: @Sendable () -> Bool

        public init(
            load: @escaping @Sendable () -> Data?,
            save: @escaping @Sendable (Data) -> Bool,
            delete: @escaping @Sendable () -> Void,
            exists: @escaping @Sendable () -> Bool
        ) {
            self.load = load
            self.save = save
            self.delete = delete
            self.exists = exists
        }
    }

    public struct StorageEnvironment: Sendable {
        public var userDefaults: @Sendable () -> UserDefaults
        public var keychain: DataStore
        public var encryptedLocal: DataStore

        public init(
            userDefaults: @escaping @Sendable () -> UserDefaults,
            keychain: DataStore,
            encryptedLocal: DataStore
        ) {
            self.userDefaults = userDefaults
            self.keychain = keychain
            self.encryptedLocal = encryptedLocal
        }

        public static let live = StorageEnvironment(
            userDefaults: { UserDefaults.standard },
            keychain: .liveKeychain,
            encryptedLocal: .liveEncryptedLocal
        )
    }

    public static var environment = StorageEnvironment.live

    public static var preferredStorageMode: BYOKCredentialStorageMode {
        let rawValue = defaults.integer(forKey: storageModeDefaultsKey)
        return BYOKCredentialStorageMode(rawValue: rawValue) ?? .keychain
    }

    public static var hasBeenConfigured: Bool {
        defaults.bool(forKey: configuredDefaultsKey) || !storedLocations().isEmpty
    }

    public static var currentStorageSummary: String {
        let locations = storedLocations()
        switch locations.count {
        case 0:
            return "Not saved yet"
        case 1:
            return "Saved in \(locations.first?.storedLocationLabel ?? "unknown storage")."
        default:
            let labels = BYOKCredentialStorageMode.allCases
                .filter { locations.contains($0) }
                .map(\.storedLocationLabel)
                .joined(separator: " and ")
            return "Saved in \(labels)."
        }
    }

    public static func load() -> BYOKCredentials {
        let defaults = defaults
        let baseURL = defaults.string(forKey: baseURLDefaultsKey) ?? ""
        let modelID = defaults.string(forKey: modelIDDefaultsKey) ?? ""
        let apiKey = loadAPIKey() ?? ""
        return BYOKCredentials(baseURL: baseURL, modelID: modelID, apiKey: apiKey)
    }

    @discardableResult
    public func save(
        storageMode: BYOKCredentialStorageMode? = nil,
        autoMigrate: Bool = true
    ) -> Bool {
        let normalized = normalizedForStorage()
        guard let data = normalized.apiKey.data(using: .utf8) else { return false }

        let targetMode = storageMode ?? Self.preferredStorageMode
        let saveSucceeded: Bool
        switch targetMode {
        case .keychain:
            saveSucceeded = Self.environment.keychain.save(data)
        case .encryptedLocalFile:
            saveSucceeded = Self.environment.encryptedLocal.save(data)
        }
        guard saveSucceeded else { return false }

        Self.defaults.set(normalized.baseURL, forKey: Self.baseURLDefaultsKey)
        Self.defaults.set(normalized.modelID, forKey: Self.modelIDDefaultsKey)
        Self.defaults.set(targetMode.rawValue, forKey: Self.storageModeDefaultsKey)
        Self.defaults.set(normalized.isConfigured, forKey: Self.configuredDefaultsKey)

        if autoMigrate {
            BYOKCredentialStorageMode.allCases
                .filter { $0 != targetMode }
                .forEach(Self.deleteStorage)
        }

        return true
    }

    public static func clear() {
        BYOKCredentialStorageMode.allCases.forEach(deleteStorage)
        defaults.removeObject(forKey: configuredDefaultsKey)
        defaults.removeObject(forKey: baseURLDefaultsKey)
        defaults.removeObject(forKey: modelIDDefaultsKey)
        defaults.removeObject(forKey: lastTestStatusDefaultsKey)
    }
}

private extension BYOKCredentials {
    static var defaults: UserDefaults {
        environment.userDefaults()
    }

    static func loadAPIKey() -> String? {
        let loadOrder = [preferredStorageMode] + BYOKCredentialStorageMode.allCases.filter { $0 != preferredStorageMode }
        for mode in loadOrder {
            let data: Data?
            switch mode {
            case .keychain:
                data = environment.keychain.load()
            case .encryptedLocalFile:
                data = environment.encryptedLocal.load()
            }
            if let data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
                return key
            }
        }
        return nil
    }

    static func storedLocations() -> Set<BYOKCredentialStorageMode> {
        var locations = Set<BYOKCredentialStorageMode>()
        if environment.keychain.exists() {
            locations.insert(.keychain)
        }
        if environment.encryptedLocal.exists() {
            locations.insert(.encryptedLocalFile)
        }
        return locations
    }

    static func deleteStorage(_ mode: BYOKCredentialStorageMode) {
        switch mode {
        case .keychain:
            environment.keychain.delete()
        case .encryptedLocalFile:
            environment.encryptedLocal.delete()
        }
    }

    func normalizedForStorage() -> BYOKCredentials {
        var normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedBaseURL.hasSuffix("/") {
            normalizedBaseURL.removeLast()
        }
        return BYOKCredentials(
            baseURL: normalizedBaseURL,
            modelID: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static var storageDirectoryURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return root.appendingPathComponent(AnkiMateIdentity.applicationSupportDirectoryName, isDirectory: true)
    }

    static var encryptedLocalCredentialURL: URL {
        storageDirectoryURL.appendingPathComponent("byok-api-key.enc")
    }

    static var encryptedLocalKeyURL: URL {
        storageDirectoryURL.appendingPathComponent("byok-api-key.key")
    }
}

private extension BYOKCredentials.DataStore {
    static let liveKeychain = BYOKCredentials.DataStore(
        load: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AnkiMateIdentity.byokKeychainService,
                kSecAttrAccount as String: AnkiMateIdentity.byokKeychainAccount,
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
                kSecAttrService as String: AnkiMateIdentity.byokKeychainService,
                kSecAttrAccount as String: AnkiMateIdentity.byokKeychainAccount
            ]
            let update = [kSecValueData as String: data]
            if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
                return true
            }
            var addQuery = query
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        },
        delete: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AnkiMateIdentity.byokKeychainService,
                kSecAttrAccount as String: AnkiMateIdentity.byokKeychainAccount
            ]
            SecItemDelete(query as CFDictionary)
        },
        exists: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: AnkiMateIdentity.byokKeychainService,
                kSecAttrAccount as String: AnkiMateIdentity.byokKeychainAccount,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true
            ]
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
    )

    static let liveEncryptedLocal = BYOKCredentials.DataStore(
        load: {
            guard let encryptedPayload = try? Data(contentsOf: BYOKCredentials.encryptedLocalCredentialURL),
                  let keyData = try? Data(contentsOf: BYOKCredentials.encryptedLocalKeyURL),
                  let sealedBox = try? AES.GCM.SealedBox(combined: encryptedPayload),
                  let plaintext = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
            else {
                return nil
            }
            return plaintext
        },
        save: { data in
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: BYOKCredentials.storageDirectoryURL, withIntermediateDirectories: true)
                try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: BYOKCredentials.storageDirectoryURL.path)

                let keyData: Data
                if let existing = try? Data(contentsOf: BYOKCredentials.encryptedLocalKeyURL) {
                    keyData = existing
                } else {
                    let key = SymmetricKey(size: .bits256)
                    keyData = key.withUnsafeBytes { Data($0) }
                    try keyData.write(to: BYOKCredentials.encryptedLocalKeyURL, options: .atomic)
                    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: BYOKCredentials.encryptedLocalKeyURL.path)
                }

                let sealedBox = try AES.GCM.seal(data, using: SymmetricKey(data: keyData))
                guard let combined = sealedBox.combined else { return false }
                try combined.write(to: BYOKCredentials.encryptedLocalCredentialURL, options: .atomic)
                try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: BYOKCredentials.encryptedLocalCredentialURL.path)
                return true
            } catch {
                return false
            }
        },
        delete: {
            try? FileManager.default.removeItem(at: BYOKCredentials.encryptedLocalCredentialURL)
            try? FileManager.default.removeItem(at: BYOKCredentials.encryptedLocalKeyURL)
        },
        exists: {
            FileManager.default.fileExists(atPath: BYOKCredentials.encryptedLocalCredentialURL.path)
        }
    )
}
