# Task 3 report: recovery library UI

## Status

DONE

## Changes

- Added a keyboard-accessible segmented Library switcher for Dictations, Recoveries, and an explicit Imports placeholder.
- Added a recovery attention count, state/expiry presentation, local WAV playback, progressive retry overrides, and confirmed permanent deletion.
- Routed retry, playback, refresh, and durable purge-claim deletion through `JobLibraryStore`; views do not access SQLite or the runner directly.
- Added Recovery retention settings for 1, 7, 30, and 90 days or Never.
- Documented that recovery audio stays local and that media import is not implemented yet.

## TDD evidence

### RED

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryPresentationTests
```

Exited 1 with the expected missing `RecoveryPresentation` errors for badge, expiry,
actions, retry state, confirmation, and retention labels.

### GREEN

The same focused command exited 0: 6 tests in `RecoveryPresentationTests` passed,
including five retention-label cases.

## Full verification

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test && make app && git diff --check
```

Exited 0. Swift Testing passed 58 tests in 6 suites, the release app built and was
ad-hoc signed, and `git diff --check` produced no output.

## Self-review

- Failed recovery deletion first acquires the existing persistent purge claim, then reuses the retention reconciler, preserving retry/delete arbitration and exact owned-path checks.
- Retry overrides are persisted as the unfinished attempt before the failed-to-queued transition, so the runner resumes the exact requested configuration.
- Delete is intentionally offered only for failed rows; queued/processing work cannot be removed while active, and ready rows have already committed and scheduled source cleanup.
- Retry overrides stay behind a disclosure control; the default path is one Retry button using current settings.
- Visible buttons retain text labels and system icons, dialogs use default/cancel keyboard actions, playback has a Space shortcut, and the recovery badge has a count-aware VoiceOver label.
- Imports has no speculative controls or media affordances beyond the requested placeholder.

## Concerns

- WAV playback uses the system audio output and exposes start-only playback; stop/scrubbing controls were not requested.
