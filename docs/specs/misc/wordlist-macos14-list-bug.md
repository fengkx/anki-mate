# ADR: WordListView macOS 14 List Rendering Bug

## Status

**Implemented** — version-conditional code shipped in `Sources/DictKitApp/Views/WordListView.swift`.

## Context

On macOS 14 (Sonoma), `List` rows inside a `NavigationSplitView` content column receive zero intrinsic width, causing all `Text` content to be invisible. Status icons and buttons render normally because they have fixed frames, but flexible-width text views collapse to zero width.

The bug does not reproduce on macOS 15+ (confirmed working on macOS 26 Tahoe).

This is a platform bug in the SwiftUI framework shipped with macOS 14.

## Decision

Use `#available(macOS 15.0, *)` to branch at the view layer:

- **macOS 15+**: native `List(selection:)` with system selection highlight, keyboard navigation, and accessibility semantics.
- **macOS 14**: `ScrollView` + `LazyVStack` compatibility shim with manual selection, highlight, keyboard navigation, and dividers.

Both paths share a single `WordRowView`. The shim path passes `isManuallySelected: true/false` to drive white-on-blue highlight; the native path passes `false` and lets the system handle selection appearance.

`selectedWordID` on `WordListViewModel` remains the single source of selection state for both paths.

## Compatibility Shim: Guaranteed Behavior

The macOS 14 fallback promises only minimum behavioral parity:

- Click to select
- Up/Down arrow key navigation (requires macOS 14+ `onKeyPress`)
- Delete key removes selected word
- Auto-scroll to selected row
- Right-click context menu (Delete)

## Known Gaps in the Shim

| Gap | Detail |
|-----|--------|
| Active/inactive selection semantics | Shim uses `Color.accentColor` unconditionally; does not dim to gray when the window loses focus, unlike native `List` |
| Accessibility | No `accessibilityAddTraits(.isSelected)` or VoiceOver row announcements |
| Focus reliability | `onKeyPress` on `ScrollView` may require `.focusable()` to reliably receive key events on macOS 14; added as a precaution |

These are accepted trade-offs for a compatibility shim targeting a single legacy OS version.

## Related Reports

- [Apple Developer Forums #746611 — NavigationSplitView column layout issues](https://developer.apple.com/forums/thread/746611)
- [Apple Developer Forums #749620 — NSTextView in NavigationSplitView](https://forums.developer.apple.com/forums/thread/749620)
- [Apple TN3154 — Adopting NavigationSplitView](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view)
- [Stack Overflow #74713371 — NavigationSplitView @State issues](https://stackoverflow.com/questions/74713371/weird-behavior-with-navigationsplitview-and-state)

## Verification

1. `just build` compiles without errors
2. macOS 14: `just run-app` — ScrollView path, text visible, selection/keyboard/delete/scroll all work
3. macOS 15+/26: `just run-app` — native List path, system selection highlight, keyboard arrows, delete key
