# Output Translation Task 7 Report

## Status

Implemented session-scoped translation failure recovery for external and
Scratchpad destinations.

## Behavior

- Translation failures remain FIFO and retain the raw transcript, source
  language, translation target, template, captured destination, and stable
  per-attempt generation.
- Retry is user-initiated, reads one fresh canonical cloud snapshot, requires
  current eligibility, and makes one request with the retained source,
  template, target, and destination.
- Cancellation, empty output, ineligible configuration, and transport errors
  never insert source text automatically.
- **Insert source text** is an explicit bypass. External AX target drift and
  Scratchpad token drift leave recoverable text visible/selectable and never
  redirect insertion to current focus.
- Late retry responses are ignored after generation invalidation. Successful
  delivery consumes the exact failure ID and preserves all other FIFO items.
- HUD and Scratchpad expose **Translation failed**, **Retry translation**, and
  **Insert source text**. Recording controls label the bypass **Use source
  text** when translation is selected and **Raw** otherwise.
- Recovery state is memory-only; external targets and editor tokens are not
  persisted across relaunch.

## TDD Evidence

RED:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TranslationRecoveryTests
exit 1: PendingTranslationRecovery,
PendingTranslationRecoveryController, and TranslationRecoveryPresentation
were not found.
```

GREEN:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TranslationRecoveryTests
8 tests in 1 suite passed.
```

Focused integration verification:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter \
  'TranslationRecoveryTests|RecordingDestinationTests|ScratchpadRecordingTests|ScratchpadPersistenceTests|ScratchpadEditorTests|FloatingControlsPresentationTests'
exit 0.
```

Full verification:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
exit 0.
```

`git diff --check` also exited 0. Pre-existing modifications to Task 1, 2, and
4 reports were left untouched and unstaged.
