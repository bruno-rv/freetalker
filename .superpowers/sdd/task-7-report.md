# Task 7 Report: Native rich-text editor and formatting commands

## Status

Implemented and verified.

## Changes

- Added a SwiftUI/AppKit rich-text bridge that creates one `NSTextView`, attaches
  the document's existing `NSTextStorage`, and leaves attributed content untouched
  in `updateNSView`.
- Added selection-aware bold, italic, heading, semantic bulleted/numbered list,
  clear-formatting, and transformation replacement commands.
- Formatting uses UTF-16 `NSString` paragraph ranges, native font traits,
  `NSTextList`, paragraph indents, and tab stops.
- Formatting changes register as one undo operation. Transformation replacement
  passes the actual `NSTextView` undo manager to `ScratchpadDocument`.
- Clear formatting removes only the editor-supported formatting attributes and
  preserves unrelated attributes such as links.

## TDD evidence

RED:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScratchpadEditorTests
error: cannot find type 'ScratchpadEditorController' in scope
error: cannot find 'RichTextEditor' in scope
```

GREEN (focused editor + persistence):

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'Scratchpad(Editor|Persistence)Tests'
Test run with 18 tests in 2 suites passed.
```

The focused suite saves a semantic bulleted list as RTF, reloads it through
`ScratchpadDocument`, and verifies the reloaded paragraph still contains an
`NSTextList` with `.disc` marker format.

Full suite:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Test run with 367 tests in 35 suites passed.
```

## Self-review

- Confirmed `updateNSView` does not reset content or selection state.
- Confirmed the bridge retains identity with `document.textStorage`.
- Confirmed emoji-aware selections and paragraph calculations use UTF-16 ranges.
- Confirmed no textual bullet prefixes or custom list serialization are used.
- Confirmed pre-existing modified Task 1, 2, and 4 reports were not staged.

## Concerns

None. AppKit's native list and undo APIs behaved as required. The test harness
hosts its text view in an `NSWindow` so it exercises the real responder-chain
undo manager rather than a synthetic substitute.

## Review fixes

Addressed both Task 7 review findings:

- Applying the requested native list now toggles it off only when every selected
  paragraph already has that list. Mixed selections deterministically apply the
  requested list to every paragraph. Toggle-off removes `NSTextList` and only
  the editor's list indents/tab stop, preserving unrelated paragraph properties.
- Ordinary typing now schedules persistence through the `NSTextStorageDelegate`
  path only. The `NSTextViewDelegate` coordinator remains the editor coordination
  point but does not schedule a duplicate save.
- Added countable `didScheduleSave` and `didSave` observation hooks while keeping
  the production RTF persistence implementation active.

Review-fix RED:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScratchpadEditorTests
error: extra arguments at positions #2, #3 in call
```

The new tests required the missing scheduling observation seam; under the prior
list implementation, the toggle-off and mixed-selection assertions also did not
have the required behavior.

Review-fix GREEN:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'Scratchpad(Editor|Persistence)Tests'
Test run with 21 tests in 2 suites passed.

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Test run with 370 tests in 35 suites passed.
```

The original corrupt-file dirty-protection test remains green, and the semantic
RTF list round-trip test still reloads an actual `.disc` `NSTextList`.
