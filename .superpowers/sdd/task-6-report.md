# Task 6 Report: Persistent Scratchpad Document

## Status

Implemented a main-actor scratchpad document backed by RTF, atomic sibling-file
replacement, debounced saves, corruption preservation, revision-bound insertion
tokens, and caller-owned grouped undo registration.

## TDD Evidence

### RED

Command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScratchpadPersistenceTests
```

The initial run exited 1 because `ScratchpadPersistence` and
`ScratchpadDocument` did not exist. A later undo-specific RED run also exited 1
because `replaceIfValid` did not yet accept an `UndoManager`.

### GREEN

Focused command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScratchpadPersistenceTests
```

Result: exit 0; 8 tests passed in 1 suite.

Full command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Result: exit 0; 357 tests passed in 34 suites.

## Implementation Notes

- RTF is loaded and encoded with `NSAttributedString` document APIs; no keyed
  archive is used.
- Saves write a temporary sibling, replace an existing destination, and move on
  first save.
- A corrupt source loads as an empty editable document with a warning. It is not
  rewritten by `flush()` until the user performs a real text-storage edit.
- All AppKit rich-text state and persistence operations are main-actor isolated.
  The legacy AppKit delegate conformance uses `@preconcurrency` at that boundary.
- Ranges and snapshots use `NSString` and `NSRange` UTF-16 semantics. Invalid or
  partial composed-character selections never receive a valid replacement map.
- Tokens map opaque UUIDs to revision, range, and original text. Any intervening
  edit clears all maps; successful tokens are single-use.
- Replacement optionally registers the inverse attributed substring with a
  caller-owned `UndoManager` under the supplied action name. The document does
  not own a speculative global undo manager.

## Self-review

- Confirmed only Task 6 source, tests, and this report are staged for the commit.
- Confirmed unrelated pre-existing report modifications remain unstaged.
- `git diff --check` reported no whitespace errors.

## Concerns

None blocking. Task 7 should pass the real `NSTextView` undo manager to
`replaceIfValid`; callers without a view can omit it.

## P1 Follow-up: Caret Boundary Safety

### RED

Added `caretTokenRequiresAComposedCharacterBoundary`, covering an invalid caret
inside the emoji in `A😀B` plus valid carets at the start and end. The focused
command exited 1 with 3 issues: the split-surrogate token was accepted, the
replacement returned `true`, and the text was corrupted to `A�invalid�B`.

### GREEN

Zero-length ranges now require the UTF-16 location to be the start of a composed
character sequence or the end of the string. Existing nonempty-range validation
is unchanged.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScratchpadPersistenceTests
```

Result: exit 0; 9 tests passed in 1 suite.
