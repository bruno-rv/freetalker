# Task 4 report — Settings and app lifecycle integration

## Delivered

- Wired the persisted Voice Edit hotkey to selection capture and a two-press spoken-instruction lifecycle.
- Pinned Voice Edit transcription and generation to local engines; no cloud processor or cloud STT path is used.
- Added a memory-only preview window with explicit Replace, Copy, and Cancel actions, keyboard shortcuts, VoiceOver labels, original/proposed text, and drift-specific recovery messages.
- Added a Snippets settings tab with create, edit/rename, delete, canonical trigger validation, persisted updates, and actionable legacy ambiguity/duplicate guidance.
- Documented mandatory confirmation and the local-only privacy boundary.

## TDD evidence

- RED: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VoiceEditPresentationTests`
  failed because `VoiceEditHotKeyPresentation`, `SnippetDraft`, `SnippetEditorPresentation`, and `VoiceEditPreviewAccessibility` did not exist.
- GREEN: the same focused command passed 6 tests in 1 suite.
- Focused integration: `swift test --filter 'VoiceEdit|Snippet'` passed 45 tests in 4 suites.

## Final verification

- `make test`: 164 tests in 17 suites passed.
- `make app`: release build, bundle assembly, and ad-hoc signing succeeded.
- `git diff --check`: clean.

## Scope note

`VoiceEditPreviewView.swift` and `VoiceEditCoordinator.swift` were adjacent, strictly necessary
edits to expose the original selection, disable stale replacement, and provide the requested
keyboard/VoiceOver presentation. The unrelated pre-existing deletions of Task 1 and Task 2 reports
were not staged or committed.

## Review follow-up

- Replaced the activating preview window with a nonactivating `NSPanel`, preserving the original
  frontmost target while retaining explicit keyboard and button actions. Selection replacement
  still performs the full double target/range/fingerprint revalidation.
- Unified dictation and Voice Edit audio ownership behind one mutually exclusive capture gate.
- Preserved snippet-store initialization errors, exposed retry guidance in Settings, and made an
  unavailable store a typed Voice Edit failure that cannot fall through to local generation.
- RED: focused tests failed on missing preview ownership, capture ownership, and storage failure APIs.
- GREEN: focused review regression suite passed 42 tests in 3 suites; full `make test` passed
  169 tests in 17 suites.

