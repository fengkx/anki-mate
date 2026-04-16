# DictKitApp Word List Persistence Design

## Goal

Persist the app word list across launches, keep case-insensitive deduplication stable, and support stale-while-revalidate behavior when a user selects a word.

This behavior is app-specific. It must live inside `DictKitApp` and must not be pushed into `DictKit`, `DictKitCLI`, or other library targets.

## Decisions

- Persistence backend: SQLite
- Ownership: `DictKitApp` only
- Database path: `~/Library/Application Support/DictKit/word-list.sqlite3`
- Deduplication rule: case-insensitive, based on `trim + lowercased()`
- Duplicate handling: ignore later inserts and keep the first-added display form
- Cached payloads: save both lookup results and synthesized audio
- SWR scope: refresh only the currently selected word
- Startup refresh policy: restore from cache only, no global background refresh

## Architecture

Add an app-private storage layer in `Sources/DictKitApp`, tentatively named `WordListStore`.

Responsibilities:

- `WordListViewModel`
  - owns UI state
  - owns the serialized lookup queue
  - triggers persistence writes after meaningful state changes
  - triggers SWR refresh when selection changes
- `WordListStore`
  - owns SQLite initialization and schema management
  - validates records before every write
  - loads and saves persisted word snapshots
  - enforces database-level uniqueness

This keeps caching and persistence as an app behavior while preserving the existing library boundaries.

## Data Model

Use a single SQLite table for the current scope:

```sql
CREATE TABLE words (
  id TEXT PRIMARY KEY,
  normalized_word TEXT NOT NULL UNIQUE,
  display_word TEXT NOT NULL,
  lookup_state_json BLOB,
  audio_data BLOB,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  last_refreshed_at REAL
);
```

Field meanings:

- `id`: stable UUID string used by the app view model
- `normalized_word`: deduplication key derived from `display_word`
- `display_word`: the first accepted word form shown in the UI
- `lookup_state_json`: serialized lookup snapshot, including loaded or failed state
- `audio_data`: synthesized audio payload for Anki export and playback reuse
- `created_at`: insertion timestamp
- `updated_at`: last successful persistence timestamp
- `last_refreshed_at`: last successful fresh lookup timestamp

## Validation Rules

Every write must pass storage-level validation before SQLite is touched.

Validation rules:

- `id` must parse as a UUID string
- `display_word`, after trimming whitespace and newlines, must be non-empty
- `normalized_word` must equal the normalized form of `display_word`
- `lookup_state_json`, when present, must be encodable and decodable as the app snapshot representation
- a loaded snapshot must include a valid `LookupResult`
- a failed snapshot must include a non-empty error message
- `audio_data`, when present, must be non-empty
- `created_at <= updated_at`
- `last_refreshed_at`, when present, must be greater than or equal to `created_at`

If validation fails, the store returns an error and skips the write entirely.

## Runtime Behavior

### App Startup

- Open or create the SQLite database
- Load persisted words ordered by `created_at`
- Rebuild `WordItem` instances in memory from the persisted snapshots
- Do not start background refresh for the whole list

### Add Word

- Normalize the user input with `trim + lowercased()`
- Reject empty input
- Reject duplicates already present in memory
- Insert into SQLite with the unique `normalized_word` constraint as a second safety net
- Only after a successful insert, append the `WordItem` to the in-memory list
- Enqueue the initial lookup

### Remove Word

- Remove the item from memory
- Delete the corresponding SQLite row

### Lookup Completion

- On successful lookup, persist the new loaded snapshot
- On lookup failure, persist the failed snapshot only when there is no previously loaded snapshot to preserve

### Audio Synthesis

- When synthesis succeeds, persist the audio payload into the same row
- If a later refresh changes the lookup result enough to invalidate the cached pronunciation basis, clear `audio_data` before saving the refreshed row

## SWR Behavior

SWR applies only when the user selects a word.

Selection flow:

1. Load and display the cached snapshot already in memory
2. Start a background fresh lookup for the selected word
3. If the fresh result differs from the cached result:
   - update the in-memory `WordItem`
   - clear stale audio if needed
   - persist the refreshed row
4. If the fresh result matches the cached result:
   - update `last_refreshed_at`
   - keep existing audio
5. If the fresh lookup fails:
   - keep showing the cached loaded snapshot when one exists
   - record the refresh failure only as transient UI state or logging
   - do not overwrite a good cached loaded snapshot with a failed persisted snapshot

This preserves the core SWR contract: stale data remains usable until a better fresh value is available.

## Testing

Add app-layer tests instead of pushing this behavior into library test targets.

Recommended target:

- `DictKitAppTests`

Coverage:

- store bootstraps schema and loads an empty database
- valid rows round-trip through SQLite
- invalid rows fail validation and are not written
- deduplication rejects case-insensitive duplicates
- startup restores cached lookup results and audio
- selection-triggered SWR keeps stale cached data visible while a refresh is in flight
- refresh success updates persistence
- refresh failure does not clobber an existing cached loaded snapshot
- deleting a word removes its persisted row

## Non-Goals

- shared caching behavior for CLI or library consumers
- whole-list background refresh on startup
- migration to SwiftData or Core Data
- multi-table normalization before there is a real need for it

## Risks and Mitigations

- SQLite schema drift
  - Keep schema minimal and versioned in the app store layer
- Large row payloads due to audio blobs
  - Accept this for now because the app scope is small and the simplest ownership model is preferable
- Cache corruption from partial writes
  - Validate before writing and rely on SQLite transaction boundaries for row updates
- UI regressions from selection-driven refresh
  - Keep cached loaded state visible until fresh data is confirmed

## Validation

The feature is complete when:

- quitting and relaunching the app restores the previous word list
- lookup results and synthesized audio survive relaunch
- adding `Apple` and `apple` results in a single row
- selecting a cached word shows cached content immediately and refreshes it in the background
- a failed refresh does not destroy an existing good cached snapshot
