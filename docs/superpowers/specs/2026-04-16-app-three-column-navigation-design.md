# DictKitApp Three-Column Navigation Design

## Goal

Restructure the macOS app layout so collection navigation, word management, and card preview are separated into three clear columns.

This change is intended to fix the current sidebar interaction model, where collection switching, collection management, word input, batch operations, and word deletion are visually mixed together and feel ambiguous.

## Decisions

- Layout model: `NavigationSplitView` with three visible columns
- Column 1 purpose: collection navigation and collection management only
- Column 2 purpose: word input and word list for the selected collection only
- Column 3 purpose: preview and word detail states only
- Collection switching model: always-visible collection list, not a picker
- Word add model: input lives at the top of the words column
- Export entry point: lives in the words column top action area
- Word delete model: always confirm, with explicit choice between removing from the current collection and deleting from all collections
- Scope: App UI and app view model only; persistence and export semantics remain unchanged

## Architecture

Keep the existing app-private collection and word persistence model, but reorganize the UI into clearer view boundaries.

Responsibilities:

- `ContentView`
  - owns the three-column shell
  - wires sheet, alert, and selection state into the correct column
- `CollectionsSidebarView`
  - shows the collection list
  - handles collection selection
  - owns collection-level actions like create, rename, and delete
- `WordsColumnView`
  - shows the current collection header and counts
  - owns single-word input, batch add entry point, and the word list
  - owns word deletion entry points
- `CardPreviewView`
  - remains the detail column for the selected word
- `WordListViewModel`
  - continues to own selection, collection switching, add/remove behavior, export state, and delete semantics
  - gains explicit state for pending word deletion confirmation

This keeps view responsibilities narrow and makes the data hierarchy match the screen hierarchy.

## Information Architecture

The data model is not flat:

- `Collection` is a navigation container
- `Word` is content
- one `Word` can belong to multiple `Collection`s

That means `Collections` and `Words` should not be merged into one list or one toolbar cluster.

Screen structure:

```text
Column 1: Collections
- Collections
- Default
- TOEFL
- Phrases
- + New Collection

Column 2: Words
- Current collection title
- Word count / ready count
- [Enter a word...] [Add]
- [Batch Add]
- Word rows for selected collection

Column 3: Preview
- Selected word card preview
- Empty state
- Loading state
- Lookup failure state
```

## Column Design

### Column 1: Collections

This column is navigation, not editing content.

UI behavior:

- Show a simple collection list with clear selected state
- Put `New Collection` in the column toolbar or header area
- Move `Rename` and `Delete` into the selected row menu or context menu
- Do not place word-level actions here

Expected result:

- the user always understands which collection is active
- collection actions are visually grouped with the collection they affect

### Column 2: Words

This column is the working area for the selected collection.

UI behavior:

- Show the selected collection name as the section header
- Show secondary metadata like `24 words` and `18 ready`
- Place the add-word text field and `Add` button at the top of the column
- Keep `Batch Add` near that input area because it is another add path
- Place `Export to Anki` in the same top action area, separate from collection navigation
- Show only the words belonging to the selected collection
- Keep row-level actions on rows or in row context menus

Expected result:

- the user sees that all word operations are scoped to the currently selected collection
- the add flow becomes local and obvious
- export is discoverable without polluting the collections column

### Column 3: Preview

This column remains focused on the currently selected word.

UI behavior:

- keep the current preview states: loaded, loading, failed, empty
- do not place collection or list-management actions here

Expected result:

- the rightmost column remains a pure detail view

## Delete Interaction

Deleting a word must no longer be a direct destructive action because a word can belong to multiple collections.

When the user asks to delete a word:

1. Show a confirmation dialog
2. State the selected word explicitly
3. Show which other collections also contain that word, if any
4. Offer three actions:
   - `Remove from "<current collection>"`
   - `Delete from all collections`
   - `Cancel`

Rules:

- `Remove from "<current collection>"` removes only the current association
- `Delete from all collections` removes the word globally and clears cached lookup/audio state
- if the word only belongs to the current collection, the dialog should still use explicit wording instead of silently changing semantics

Example copy:

- Title: `Delete "Apple"?`
- Message when shared: `"Apple" is also in TOEFL, Phrases.`
- Primary actions:
  - `Remove from Default`
  - `Delete Everywhere`
  - `Cancel`

## State Flow

### Collection Selection

- selecting a collection updates the current collection ID in the view model
- the words column reloads to show only that collection's words
- the preview remains bound to the selected word when it still exists in the current list
- if the selected word is not in the new collection, clear the selection

### Add Word

- input in the words column adds only to the currently selected collection
- batch add follows the same rule
- no collection chooser is needed in the add flow because collection context is already visible

### Export

- the export button is shown in the words column top action area
- opening export defaults to the currently selected collection
- the export sheet still allows selecting one or more collections before writing the `.apkg`
- export remains an app-level content action, not a collection-row action and not a global preview action

### Delete Word

- user triggers delete from row menu, keyboard shortcut, or delete button
- view model stores pending delete intent
- UI presents a confirmation dialog using view model-provided context
- chosen action calls either:
  - remove current association
  - delete the word globally

## View Model Changes

Add explicit state for delete confirmation instead of deleting immediately from view actions.

Suggested shape:

```swift
struct PendingWordDeletion: Identifiable, Equatable {
    let wordID: UUID
    let word: String
    let currentCollectionName: String
    let otherCollectionNames: [String]
}
```

Responsibilities:

- build deletion context from collection membership
- expose pending delete state for UI binding
- confirm current-collection removal
- confirm global deletion
- clear pending state after confirm or cancel

This keeps destructive branching logic out of the view layer.

## Testing

Add and update app-layer tests only.

Coverage:

- collection list remains visible independently from the words column
- selecting a collection updates the words column contents
- add-word actions still target only the selected collection
- requesting delete creates the correct pending delete state
- pending delete state includes other collection names when the word is shared
- confirming `Remove from current collection` removes only that association
- confirming `Delete from all collections` removes the word globally
- switching collections clears an invalid selected word

If practical, add lightweight view-model-focused tests for delete dialog state and keep UI structure verification minimal.

## Non-Goals

- redesigning the visual style of the preview card
- changing SQLite schema or export format
- introducing collection search
- moving export into the collections column or a collection row action
- changing SWR behavior

## Risks and Mitigations

- Three columns can feel crowded on narrow widths
  - keep column responsibilities narrow and let the words column own the main working controls
- Too many row actions can still recreate clutter
  - move collection actions into row menus and keep headers minimal
- Delete behavior can become confusing if wording is vague
  - use explicit dialog copy that names the current collection and the cross-collection impact

## Validation

The redesign is complete when:

- the app shows collections, words, and preview in three separate columns
- collection actions no longer share the same visual cluster with word actions
- adding a word is obviously scoped to the selected collection
- exporting to Anki is accessible from the words column top area
- deleting a word always opens a confirmation dialog
- the dialog clearly distinguishes removing from the current collection versus deleting everywhere
- shared-word dialogs display the other collections that would be affected
