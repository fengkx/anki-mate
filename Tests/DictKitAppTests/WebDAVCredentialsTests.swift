import AnkiMateShared
import Foundation
import XCTest
@testable import DictKitApp

final class WebDAVCredentialsTests: XCTestCase {
    override func tearDown() {
        WebDAVCredentials.environment = .live
        super.tearDown()
    }

    func testEncryptedLocalStorageRoundTripsWithoutPlaintext() throws {
        let context = try makeTestContext()
        WebDAVCredentials.environment = context.environment

        let credentials = WebDAVCredentials(
            serverURL: "https://example.com/dav/",
            username: "reader",
            password: "hunter2"
        )

        XCTAssertTrue(credentials.save(storageMode: .encryptedLocalFile, autoMigrate: true))
        XCTAssertEqual(WebDAVCredentials.load(), credentials)

        let encryptedFileURL = context.baseURL
            .appendingPathComponent(AnkiMateIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("webdav-credentials.enc")
        let encryptedPayload = try Data(contentsOf: encryptedFileURL)
        let encryptedText = String(decoding: encryptedPayload, as: UTF8.self)

        XCTAssertFalse(encryptedText.contains("hunter2"))
        XCTAssertFalse(encryptedText.contains("reader"))
        XCTAssertFalse(encryptedText.contains("example.com"))
    }

    func testDefaultSaveAutomaticallyMigratesToNewStorage() throws {
        let context = try makeTestContext()
        WebDAVCredentials.environment = context.environment

        let credentials = WebDAVCredentials(
            serverURL: "https://example.com/dav/",
            username: "reader",
            password: "secret"
        )

        XCTAssertTrue(credentials.save(storageMode: .keychain, autoMigrate: true))
        XCTAssertTrue(context.keychain.hasValue)

        XCTAssertTrue(credentials.save(storageMode: .encryptedLocalFile, autoMigrate: true))

        XCTAssertFalse(context.keychain.hasValue)
        XCTAssertEqual(WebDAVCredentials.storedLocations(), [.encryptedLocalFile])
    }

    func testExplicitlyDisablingAutoMigrationKeepsPreviousStorageCopy() throws {
        let context = try makeTestContext()
        WebDAVCredentials.environment = context.environment

        let credentials = WebDAVCredentials(
            serverURL: "https://example.com/dav/",
            username: "reader",
            password: "secret"
        )

        XCTAssertTrue(credentials.save(storageMode: .keychain, autoMigrate: true))
        XCTAssertTrue(credentials.save(storageMode: .encryptedLocalFile, autoMigrate: false))

        XCTAssertTrue(context.keychain.hasValue)
        XCTAssertEqual(WebDAVCredentials.storedLocations(), [.keychain, .encryptedLocalFile])
    }

    func testLoadFallsBackToExistingStorageWhenPreferredModeHasNoCopy() throws {
        let context = try makeTestContext()
        WebDAVCredentials.environment = context.environment

        let credentials = WebDAVCredentials(
            serverURL: "https://example.com/dav/",
            username: "reader",
            password: "secret"
        )

        XCTAssertTrue(credentials.save(storageMode: .keychain, autoMigrate: true))
        context.defaults.set(WebDAVCredentialStorageMode.encryptedLocalFile.rawValue, forKey: "webdav_storage_mode")

        XCTAssertEqual(WebDAVCredentials.load(), credentials)
    }
}

private extension WebDAVCredentialsTests {
    struct TestContext {
        let baseURL: URL
        let defaults: UserDefaults
        let keychain: InMemoryKeychain
        let environment: WebDAVCredentials.StorageEnvironment
    }

    final class InMemoryKeychain: @unchecked Sendable {
        var data: Data?
        var hasValue: Bool { data != nil }
    }

    final class UserDefaultsBox: @unchecked Sendable {
        let value: UserDefaults

        init(_ value: UserDefaults) {
            self.value = value
        }
    }

    func makeTestContext() throws -> TestContext {
        let suiteName = "WebDAVCredentialsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let defaultsBox = UserDefaultsBox(defaults)

        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let keychain = InMemoryKeychain()
        let environment = WebDAVCredentials.StorageEnvironment(
            userDefaults: { defaultsBox.value },
            applicationSupportDirectory: { baseURL },
            keychain: WebDAVCredentials.KeychainAccess(
                load: { keychain.data },
                save: { data in
                    keychain.data = data
                    return true
                },
                delete: {
                    keychain.data = nil
                },
                exists: {
                    keychain.data != nil
                }
            )
        )

        addTeardownBlock {
            WebDAVCredentials.environment = .live
            defaults.removePersistentDomain(forName: suiteName)
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
