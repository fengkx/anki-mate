import XCTest
@testable import AnkiMateLLM

final class BYOKCredentialTests: XCTestCase {
    override func tearDown() {
        BYOKCredentials.environment = .live
        super.tearDown()
    }

    func testSaveLoadFromKeychainAbstraction() {
        let store = InMemoryBYOKCredentialStore()
        BYOKCredentials.environment = store.environment

        let credentials = BYOKCredentials(baseURL: "https://api.example.com", modelID: "test-model", apiKey: "secret-key")

        XCTAssertTrue(credentials.save(storageMode: .keychain))

        XCTAssertEqual(BYOKCredentials.load(), credentials)
        XCTAssertEqual(BYOKCredentials.currentStorageSummary, "Saved in Keychain.")
        XCTAssertTrue(BYOKCredentials.hasBeenConfigured)
    }

    func testSaveLoadFromEncryptedLocalStorage() {
        let store = InMemoryBYOKCredentialStore()
        BYOKCredentials.environment = store.environment

        let credentials = BYOKCredentials(baseURL: "https://api.example.com", modelID: "test-model", apiKey: "secret-key")

        XCTAssertTrue(credentials.save(storageMode: .encryptedLocalFile))

        XCTAssertEqual(BYOKCredentials.load(), credentials)
        XCTAssertEqual(BYOKCredentials.currentStorageSummary, "Saved in encrypted local storage.")
        XCTAssertTrue(BYOKCredentials.hasBeenConfigured)
    }

    func testChangingStorageModeRemovesPreviousCopy() {
        let store = InMemoryBYOKCredentialStore()
        BYOKCredentials.environment = store.environment

        let credentials = BYOKCredentials(baseURL: "https://api.example.com", modelID: "test-model", apiKey: "secret-key")

        XCTAssertTrue(credentials.save(storageMode: .keychain))
        XCTAssertTrue(credentials.save(storageMode: .encryptedLocalFile))

        XCTAssertFalse(store.keychainExists)
        XCTAssertTrue(store.encryptedLocalExists)
        XCTAssertEqual(BYOKCredentials.load(), credentials)
    }

    func testHasBeenConfiguredDoesNotRequireLoadingSecret() {
        let store = InMemoryBYOKCredentialStore()
        store.defaults.set(true, forKey: BYOKCredentials.configuredDefaultsKey)
        BYOKCredentials.environment = store.environment

        XCTAssertTrue(BYOKCredentials.hasBeenConfigured)
        XCTAssertEqual(store.loadCount, 0)
    }
}

private final class InMemoryBYOKCredentialStore {
    let defaults = UserDefaults(suiteName: "BYOKCredentialTests-\(UUID().uuidString)")!
    var keychainData: Data?
    var encryptedLocalData: Data?
    var loadCount = 0

    var keychainExists: Bool { keychainData != nil }
    var encryptedLocalExists: Bool { encryptedLocalData != nil }

    var environment: BYOKCredentials.StorageEnvironment {
        BYOKCredentials.StorageEnvironment(
            userDefaults: { self.defaults },
            keychain: .init(
                load: {
                    self.loadCount += 1
                    return self.keychainData
                },
                save: { data in
                    self.keychainData = data
                    return true
                },
                delete: {
                    self.keychainData = nil
                },
                exists: {
                    self.keychainData != nil
                }
            ),
            encryptedLocal: .init(
                load: {
                    self.loadCount += 1
                    return self.encryptedLocalData
                },
                save: { data in
                    self.encryptedLocalData = data
                    return true
                },
                delete: {
                    self.encryptedLocalData = nil
                },
                exists: {
                    self.encryptedLocalData != nil
                }
            )
        )
    }
}
