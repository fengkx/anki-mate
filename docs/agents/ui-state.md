# UI State Sync SOP

Use this file for any task involving SwiftUI, view models, persistence, sync, downloads, or background status.

## Why These Bugs Happen

Most "state changed but UI did not update" bugs in this codebase come from one of these patterns:

1. State changed in persistence, but the in-memory view model was never reloaded.
2. A parent `ObservableObject` derived UI from child `ObservableObject`s, but did not forward child changes.
3. UI mutated display state directly, but skipped the persistence path, so the next reload lost the change.
4. Async work updated nested mutable state in place, but the published container did not emit a reliable change.
5. Status propagation was throttled, delayed, or split across too many layers, so UI timing became nondeterministic.

These bugs are systemic, not incidental. SwiftUI only stays correct when ownership, propagation, and persistence boundaries are explicit.

## State Ownership Rules

1. Every user-visible state must have one clear source of truth.
2. If UI is backed by store data, all writes must go through a persistence-aware path.
3. If UI is backed by a view model cache, any out-of-band store write must explicitly trigger reload or merge.
4. Do not let views mutate durable state ad hoc. Views should call intent methods on the owning view model or service.
5. If a parent view model computes derived UI from child objects, it must subscribe to child change events and forward them.

## Required Patterns

### Store write -> UI refresh

If a service writes to the store outside the active view model, it must do one of:

- call a reload hook on the owning view model
- merge the written entities back into the in-memory cache
- publish a domain event that the view model consumes immediately

Never assume "the UI will notice" after a database write.

### Parent view model -> child observable objects

If a parent owns `[ChildItem]` and derives counts, summaries, filters, or badges from those items:

- subscribe to every child `objectWillChange`
- forward the event through the parent `objectWillChange`
- rebuild subscriptions whenever the collection is replaced
- remove subscriptions when items are removed

Without this, row UI may refresh while parent-level aggregates stay stale.

### Durable UI actions

For AI generation, sync, import, export, and background tasks:

- UI actions must call a view model or service method
- that method must update memory and persistence together
- success paths and clear/reset paths must both persist

Do not write `item.someField = ...` in a view when the field must survive reload.

### Published container updates

For `@Published` dictionaries, arrays, or structs:

- prefer whole-value replacement over deep in-place mutation
- encapsulate updates in helper methods
- avoid relying on nested optional subscript mutation to trigger publication

Example: replace `downloads[id]?.state = .downloading` with read-modify-write on the full value.

### Async status updates

Throttle only when there is a measured rendering problem. Do not throttle by default.

For progress, phase, sync, and download state:

- prefer prompt main-thread delivery
- keep the propagation path short
- avoid multiple layers independently caching the same status

## Review Checklist

1. What is the single source of truth for this state?
2. After a successful write, which object causes the visible UI to refresh?
3. If the store changes outside the current screen, how does the screen learn about it?
4. Are any parent-level labels, counters, badges, or disabled states derived from child objects?
5. If yes, does the parent subscribe to child changes?
6. Does every success, failure, cancel, and clear path update the same state pipeline?
7. Does the change survive reload, relaunch, and navigation away/back?
8. Is any `@Published` container being mutated in place in a way that may skip emission?
9. Is any status event being throttled without measured justification?

## Test SOP

Every stateful UI feature should have tests for these cases where applicable:

1. initial load reflects persisted state
2. local mutation updates derived UI state immediately
3. external store mutation becomes visible without relaunch
4. async success updates UI and persistence
5. async failure updates UI correctly and leaves no half-updated state
6. clear/reset actions persist, not just display
7. aggregates, counts, badges, and button enabled states change with child item updates

Prefer view-model and service tests over brittle UI snapshot tests for state propagation.

## Anti-Patterns

- writing persistent fields directly from SwiftUI views
- assuming `@Published` always emits for nested mutations
- having both service and view model keep separate unsynchronized copies of the same status
- reloading only on app launch
- updating row state without considering parent-derived UI

## Definition of Done

A UI/state change is not done until:

1. the source of truth is explicit
2. propagation to visible UI is explicit
3. persistence behavior is explicit
4. external update behavior is explicit
5. regression tests cover the state transitions
