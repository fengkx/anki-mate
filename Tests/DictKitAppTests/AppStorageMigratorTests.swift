import AnkiMateShared
import Foundation
import XCTest
@testable import DictKitApp

final class AppStorageMigratorTests: XCTestCase {
    override func tearDown() {
        AppStorageMigrator.environment = .live
        super.tearDown()
    }

    func testMigratesLegacyDefaultsDomainIntoCurrentDefaults() throws {
        let context = try makeContext()
        AppStorageMigrator.environment = context.environment

        context.defaults.setPersistentDomain(
            [
                "sync_interval_seconds": 1800,
                "ankimate.selectedModelId": "qwen-test"
            ],
            forName: AnkiMateIdentity.legacyBundleIdentifiers[0]
        )

        AppStorageMigrator.migrateCurrentDeviceData()

        XCTAssertEqual(context.defaults.integer(forKey: "sync_interval_seconds"), 1800)
        XCTAssertEqual(context.defaults.string(forKey: "ankimate.selectedModelId"), "qwen-test")
        XCTAssertNil(context.defaults.persistentDomain(forName: AnkiMateIdentity.legacyBundleIdentifiers[0]))
    }

    func testMigratesLegacyApplicationSupportDirectory() throws {
        let context = try makeContext()
        AppStorageMigrator.environment = context.environment

        let legacyDirectory = context.baseURL.appendingPathComponent(
            AnkiMateIdentity.legacyApplicationSupportDirectoryNames[0],
            isDirectory: true
        )
        let legacyDatabase = legacyDirectory.appendingPathComponent("word-list.sqlite3")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacyDatabase)

        AppStorageMigrator.migrateCurrentDeviceData()

        let newDirectory = context.baseURL.appendingPathComponent(
            AnkiMateIdentity.applicationSupportDirectoryName,
            isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDirectory.appendingPathComponent("word-list.sqlite3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }

    func testMigratesLegacyWebDAVKeychainEntry() throws {
        let context = try makeContext()
        AppStorageMigrator.environment = context.environment

        let credentialsData = Data("secret".utf8)
        context.keychain.storage["com.anki-mate.webdav|credentials"] = credentialsData

        AppStorageMigrator.migrateCurrentDeviceData()

        XCTAssertEqual(
            context.keychain.storage["\(AnkiMateIdentity.webDAVKeychainService)|\(AnkiMateIdentity.webDAVKeychainAccount)"],
            credentialsData
        )
        XCTAssertNil(context.keychain.storage["com.anki-mate.webdav|credentials"])
    }
}

private extension AppStorageMigratorTests {
    struct TestContext {
        let baseURL: URL
        let defaults: UserDefaults
        let keychain: InMemoryKeychain
        let environment: AppStorageMigrator.Environment
    }

    final class InMemoryKeychain: @unchecked Sendable {
        var storage: [String: Data] = [:]
    }

    final class UserDefaultsBox: @unchecked Sendable {
        let value: UserDefaults

        init(_ value: UserDefaults) {
            self.value = value
        }
    }

    func makeContext() throws -> TestContext {
        let suiteName = "AppStorageMigratorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.removePersistentDomain(forName: AnkiMateIdentity.legacyBundleIdentifiers[0])
        let defaultsBox = UserDefaultsBox(defaults)

        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let keychain = InMemoryKeychain()
        let environment = AppStorageMigrator.Environment(
            defaults: defaults,
            applicationSupportDirectory: { baseURL },
            loadKeychainData: { service, account in
                keychain.storage["\(service)|\(account)"]
            },
            saveKeychainData: { service, account, data in
                keychain.storage["\(service)|\(account)"] = data
                return true
            },
            deleteKeychainEntry: { service, account in
                keychain.storage.removeValue(forKey: "\(service)|\(account)")
            }
        )

        addTeardownBlock {
            AppStorageMigrator.environment = .live
            defaultsBox.value.removePersistentDomain(forName: suiteName)
            defaultsBox.value.removePersistentDomain(forName: AnkiMateIdentity.legacyBundleIdentifiers[0])
            try? FileManager.default.removeItem(at: baseURL)
        }

        return TestContext(
            baseURL: baseURL,
            defaults: defaults,
            keychain: keychain,
            environment: environment
        )
    }
}
