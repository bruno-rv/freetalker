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

## P1/P2 Review Fixes

- Added a weak, main-actor `TranslationRecoveryPresentationRouting` channel.
  Scratchpad registers on initialization/open, unregisters on close, and always
  re-reads the coordinator's current FIFO presentation when notified.
- Coordinator notifications now cover enqueue, retry start, retry completion,
  failure/cancellation, source insertion, exact consume, FIFO advance, and
  final clear. HUD refreshes through the same state transition path.
- Recovery presentation exposes `isRetrying`, `actionsEnabled`, and an optional
  actionable error. Both retry and source actions are disabled for the matching
  in-flight item; direct source insertion is guarded too.
- Added production-connected `AppCoordinator` tests using its real failure
  queue, weak presentation router, controlled translator, and delivery seam.
  These verify immediate enqueue presentation, in-flight disabling, successful
  FIFO advance, failure restoration/error copy, exact consumption, and final
  UI clear.

Review-fix RED:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TranslationRecoveryTests
exit 1: missing TranslationRecoveryPresentationRouting, coordinator routing
and controlled recovery seams, actionsEnabled, and errorText.
```

Review-fix GREEN:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TranslationRecoveryTests
12 tests in 1 serialized suite passed.

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter \
  'TranslationRecoveryTests|RecordingDestinationTests|ScratchpadRecordingTests|ScratchpadPersistenceTests|ScratchpadEditorTests|FloatingControlsPresentationTests|HUDWarningPresentationTests'
exit 0.

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
exit 0.
```

The recovery suite is serialized because its production-connected tests share
the application singleton. The first concurrent focused run exposed that test
isolation requirement and was stopped; the serialized rerun passed.

## Corrected P1: HUD Ownership Arbitration

- Added explicit `.none` / `.recovery` / `.recording` HUD ownership in the
  coordinator. Recovery queue and Scratchpad-router updates always continue,
  but recovery may show or hide HUD content only while recording does not own
  it.
- Recording panels, dictation processing, Scratchpad processing, and voice-edit
  capture/processing claim HUD ownership. Cancellation and processing terminal
  paths release it and present the next pending recovery at that defined idle
  transition.
- Recording ownership carries a UUID generation. Completion from an older
  processing generation cannot release a newer recording panel's ownership.
- Removed direct translation-failure HUD writes from pipeline callbacks; they
  now flow exclusively through arbitration.

Corrected-P1 RED:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TranslationRecoveryTests
exit 1: missing TranslationRecoveryHUDOwner and recording HUD claim/release
APIs. A second RED required generation-aware terminal release.
```

Corrected-P1 GREEN:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TranslationRecoveryTests
15 tests in 1 serialized suite passed.

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter \
  'TranslationRecoveryTests|HUDWarningPresentationTests|RecordingDestinationTests|RecordingOutputSelectionTests|ScratchpadRecordingTests|ScratchpadPersistenceTests|FloatingControlsPresentationTests'
exit 0.

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
exit 0.
```

The production regressions cover a visible recovery followed by newer
recording ownership while a retry completes, late enqueue during recording,
safe terminal re-presentation, and stale terminal generation rejection.
