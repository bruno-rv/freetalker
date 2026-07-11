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

## Review follow-up: atomic retry, live façade updates, and playback errors

### Root causes

- Retry created an unfinished attempt and queued the job in separate actor calls, so the second write could fail and leave an orphan attempt.
- `LibraryView` observed `AppCoordinator`, not the nested `JobLibraryStore`, and capture bypassed the façade, so published recovery changes did not reliably invalidate the badge/list.
- Row state labels/icons duplicated presentation mappings.
- `AVAudioPlayer.play()` returns `false` when playback cannot start, but that result was ignored.

### RED

Focused store/façade tests exited 1 with expected missing `queueRecoveryRetry`, `preserve`,
playback protocol/error, playback-factory injection, and runner change-callback APIs. A separate
focused runner test exited 1 because `LocalJobRunner` had no `didChange` argument.

### Changes

- Added `queueRecoveryRetry` as one `BEGIN IMMEDIATE` transaction. Its insert requires a failed
  recovery, no purge claim, and no unfinished attempt; its failed-to-queued update and configured
  attempt commit or roll back together.
- `JobLibraryStore.retry` now uses only the atomic API before enqueueing.
- Recovery capture now goes through `JobLibraryStore.preserve`, which refreshes published jobs;
  retry and delete also refresh, and the runner publishes processing/terminal changes back to the
  façade.
- The segmented recovery label directly observes `JobLibraryStore`, while `RecoveriesView`
  continues to observe the same instance.
- Actual picker/row rendering now uses badge, state-label, state-icon, stage, expiry, and action
  presentation helpers without private duplicate state switches.
- Playback creation is injectable; a `false` start throws typed `RecoveryPlaybackError` for the
  existing visible alert path.

### Verification

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test && make app && git diff --check
```

Exited 0: 67 tests in 6 suites passed, the release app assembled and signed, and the diff check
produced no output. New coverage includes two-connection retry concurrency, injected transition
rollback, capture/retry/delete publication, façade retry-versus-delete arbitration, runner state
notifications, presentation mappings, and rejected playback start.

### Concerns

None beyond the intentionally start-only playback scope recorded above.
