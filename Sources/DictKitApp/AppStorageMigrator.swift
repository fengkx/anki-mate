import AnkiMateShared
import Foundation
import Security

enum AppStorageMigrator {
    struct Environment {
        var defaults: UserDefaults
        var applicationSupportDirectory: () -> URL
        var loadKeychainData: (_ service: String, _ account: String) -> Data?
        var saveKeychainData: (_ service: String, _ account: String, _ data: Data) -> Bool
        var deleteKeychainEntry: (_ service: String, _ account: String) -> Void

        static let live = Environment(
            defaults: .standard,
            applicationSupportDirectory: {
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                        "Library/Application Support",
                        isDirectory: true
                    )
            },
            loadKeychainData: { service, account in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess else { return nil }
                return result as? Data
            },
            saveKeychainData: { service, account, data in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
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
            deleteKeychainEntry: { service, account in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                SecItemDelete(query as CFDictionary)
            }
        )
    }

    static var environment = Environment.live

    static func migrateCurrentDeviceData() {
        migrateUserDefaults()
        migrateApplicationSupportDirectory()
        migrateWebDAVCredentials()
    }
}

private extension AppStorageMigrator {
    static func migrateUserDefaults() {
        let defaults = environment.defaults

        for legacyDomain in AnkiMateIdentity.legacyBundleIdentifiers {
            guard let values = defaults.persistentDomain(forName: legacyDomain), !values.isEmpty else {
                continue
            }

            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }

            defaults.removePersistentDomain(forName: legacyDomain)
        }
    }

    static func migrateApplicationSupportDirectory() {
        let fileManager = FileManager.default
        let rootDirectory = environment.applicationSupportDirectory()
        let targetDirectory = rootDirectory.appendingPathComponent(
            AnkiMateIdentity.applicationSupportDirectoryName,
            isDirectory: true
        )

        for legacyName in AnkiMateIdentity.legacyApplicationSupportDirectoryNames {
            let legacyDirectory = rootDirectory.appendingPathComponent(legacyName, isDirectory: true)
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: legacyDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            if !fileManager.fileExists(atPath: targetDirectory.path) {
                do {
                    try fileManager.moveItem(at: legacyDirectory, to: targetDirectory)
                    continue
                } catch {
                    // Fall back to a merge if the rename cannot be completed directly.
                }
            }

            mergeDirectoryContents(from: legacyDirectory, to: targetDirectory)
            removeDirectoryIfEmpty(legacyDirectory)
        }
    }

    static func migrateWebDAVCredentials() {
        let account = AnkiMateIdentity.webDAVKeychainAccount
        let targetService = AnkiMateIdentity.webDAVKeychainService
        var targetData = environment.loadKeychainData(targetService, account)

        for legacyService in AnkiMateIdentity.legacyWebDAVKeychainServices where legacyService != targetService {
            guard let legacyData = environment.loadKeychainData(legacyService, account) else {
                continue
            }

            if targetData == nil, environment.saveKeychainData(targetService, account, legacyData) {
                targetData = environment.loadKeychainData(targetService, account) ?? legacyData
            }

            if targetData != nil {
                environment.deleteKeychainEntry(legacyService, account)
            }
        }
    }

    static func mergeDirectoryContents(from sourceDirectory: URL, to destinationDirectory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        guard let entries = try? fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for sourceEntry in entries {
            let destinationEntry = destinationDirectory.appendingPathComponent(sourceEntry.lastPathComponent)
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: sourceEntry.path, isDirectory: &isDirectory) else {
                continue
            }

            if !fileManager.fileExists(atPath: destinationEntry.path) {
                try? fileManager.moveItem(at: sourceEntry, to: destinationEntry)
                continue
            }

            guard isDirectory.boolValue else {
                continue
            }

            mergeDirectoryContents(from: sourceEntry, to: destinationEntry)
            removeDirectoryIfEmpty(sourceEntry)
        }
    }

    static func removeDirectoryIfEmpty(_ directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path), entries.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }
}
