import DictKitAnkiExport
import XCTest
@testable import DictKitApp

final class AIContentDraftStateTests: XCTestCase {
    func testInlineTextDraftStatePreservesDirtyDraftAcrossRefresh() {
        var state = AIInlineTextDraftState()

        state.mergePersistedValue("Persisted")
        state.updateDraft("Local edit")
        state.mergePersistedValue("Persisted")

        XCTAssertEqual(state.draft, "Local edit")
        XCTAssertEqual(state.lastPersistedValue, "Persisted")
        XCTAssertTrue(state.isDirty)
    }

    func testDraftListSynchronizerKeepsStableIdentityAcrossDeleteAndReorder() {
        let initial = AIDraftListSynchronizer.sync(
            persistedValues: ["first", "second", "third"],
            currentState: AIDraftListState<String, String>(),
            draftValue: { $0 }
        ).state

        let firstRowID = try! XCTUnwrap(initial.rowOrder[safe: 0])
        let secondRowID = try! XCTUnwrap(initial.rowOrder[safe: 1])
        let thirdRowID = try! XCTUnwrap(initial.rowOrder[safe: 2])

        var dirtyState = initial
        dirtyState.drafts[secondRowID] = "second draft"

        let synced = AIDraftListSynchronizer.sync(
            persistedValues: ["third", "second"],
            currentState: dirtyState,
            draftValue: { $0 }
        )

        XCTAssertEqual(synced.state.rowOrder, [thirdRowID, secondRowID])
        XCTAssertEqual(synced.state.drafts[secondRowID], "second draft")
        XCTAssertEqual(synced.removedRowIDs, [firstRowID])
    }

    func testDraftListSynchronizerPreservesRowIdentityWhenPersistedValueCatchesUpToDraft() {
        let initial = AIDraftListSynchronizer.sync(
            persistedValues: [
                ExampleSentenceArtifact(text: "Original — 原始", translation: "原始")
            ],
            currentState: AIDraftListState<ExampleSentenceArtifact, String>(),
            draftValue: \.text
        ).state
        let rowID = try! XCTUnwrap(initial.rowOrder.only)

        var dirtyState = initial
        dirtyState.drafts[rowID] = "Edited — 编辑后"

        let persisted = ExampleSentenceArtifact(text: "Edited — 编辑后", translation: "编辑后")
        let synced = AIDraftListSynchronizer.sync(
            persistedValues: [persisted],
            currentState: dirtyState,
            draftValue: \.text
        )

        XCTAssertEqual(synced.state.rowOrder, [rowID])
        XCTAssertEqual(synced.state.persistedByRowID[rowID], persisted)
        XCTAssertEqual(synced.state.drafts[rowID], "Edited — 编辑后")
    }

    func testExampleArtifactEditorDerivesTranslationFromEditedText() {
        let original = ExampleSentenceArtifact(
            text: "Original — 原始",
            translation: "原始",
            note: "Keep note"
        )

        let rewritten = AIExampleArtifactEditor.artifact(
            byApplyingEditedText: "Updated example — 更新后的翻译",
            to: original
        )
        let plainText = AIExampleArtifactEditor.artifact(
            byApplyingEditedText: "Updated example only",
            to: original
        )

        XCTAssertEqual(rewritten.text, "Updated example — 更新后的翻译")
        XCTAssertEqual(rewritten.translation, "更新后的翻译")
        XCTAssertEqual(rewritten.note, "Keep note")
        XCTAssertNil(plainText.translation)
    }

    func testRecallDraftEditorReducerKeepsLatestSelectedModeDuringTextEdits() {
        let staleDraft = RecallCardDraft(
            mode: .fullSpelling,
            front: "old front",
            back: "answer",
            hint: "nudge"
        )

        let updated = RecallDraftEditorReducer.applying(
            .front("edited front"),
            to: staleDraft,
            selectedMode: .targetedLetterCloze
        )

        XCTAssertEqual(updated.mode, .targetedLetterCloze)
        XCTAssertEqual(updated.front, "edited front")
        XCTAssertEqual(updated.back, "answer")
        XCTAssertEqual(updated.hint, "nudge")
    }

    func testRecallDraftEditorReducerCanClearHintExplicitly() {
        let draft = RecallCardDraft(
            mode: .phraseRecall,
            front: "prompt",
            back: "answer",
            hint: "remove me"
        )

        let updated = RecallDraftEditorReducer.applying(
            .hint(nil),
            to: draft,
            selectedMode: .phraseRecall
        )

        XCTAssertNil(updated.hint)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }

    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
