import Foundation
import XCTest
@testable import DictKitApp

@MainActor
final class CommandPaletteHistoryStoreTests: XCTestCase {
    func testRecordWordMovesItToFrontAndCapsLength() {
        let defaults = makeDefaults()
        let store = CommandPaletteHistoryStore(defaults: defaults)
        let ids = (0..<6).map { _ in UUID() }

        ids.forEach { store.recordWord($0) }
        store.recordWord(ids[2])

        let history = store.load()

        XCTAssertEqual(history.recentWordIDs.count, 5)
        XCTAssertEqual(history.recentWordIDs.first, ids[2])
        XCTAssertFalse(history.recentWordIDs.contains(ids[0]))
    }

    func testRecordCommandMovesItToFrontAndCapsLength() {
        let defaults = makeDefaults()
        let store = CommandPaletteHistoryStore(defaults: defaults)

        ["a", "b", "c", "d", "e", "f"].forEach { store.recordCommand($0) }
        store.recordCommand("c")

        let history = store.load()

        XCTAssertEqual(history.recentCommandIDs, ["c", "f", "e", "d", "b"])
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CommandPaletteHistoryStoreTests.\(UUID().uuidString)")!
    }
}
