# Task 2 report: retry pipeline and AppCoordinator integration

## Status

DONE

## Changes

- Added `RecoveryRetryPipeline`, with one persisted attempt per execution, cooperative cancellation checks, configuration forwarding, WAV loading, and exact source cleanup.
- Ordered successful recovery as transcription/post-processing, Dictation persistence through the existing `processDictation` injection, attempt completion, job-ready transition, then source removal.
- Preserved the source on processing or Dictation database failure and persisted the attempt failure stage/message.
- Kept raw-transcript fallback behavior by routing recovery through `AppCoordinator.processDictation`.
- Replaced the hidden `saveFailedAudio` path with atomic `RecoveryCaptureService.preserve` integration.
- Added launch recovery ordering: recover interrupted processing jobs, reconcile/purge retention, then resume the serial queue.
- Extended `LocalJobRunner` with an opt-in pipeline-owned finalization mode; its default finalization and concurrency behavior remain unchanged.

## TDD evidence

### RED

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryRetryTests
```

Result: exit 1 with the expected missing-feature errors:

```text
error: cannot find type 'RecoveryDictation' in scope
error: cannot find type 'RecoveryRetryPipeline' in scope
```

### GREEN

Commands:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryRetryTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalJobRunnerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
```

Results: exit 0; 5 recovery retry tests and 10 runner tests passed, and the release build completed.

### Full verification

Command:

```text
make test && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release && git diff --check
```

Result: exit 0; 42 tests in 5 suites passed, the release build completed, and `git diff --check` produced no output.

## Self-review

- Each retry begins exactly one attempt; an interrupted unfinished attempt remains audit history and the resumed retry gets the next attempt number.
- Attempt configuration is forwarded unchanged, including language, speech model, and template overrides.
- No source removal occurs before Dictation persistence and the ready transition both succeed.
- A post-processing failure follows the established raw fallback and records raw text as the refined text rather than failing the recovery.
- AppCoordinator remains MainActor-isolated while the serial runner and pipeline use inherited async tasks; no detached work was added.
- Existing runner clients retain runner-owned ready finalization and their cancellation/read-count regressions remain green.

## Concerns

None at initial implementation; subsequent review findings are addressed below.

## Review follow-up: durable restart, finalization arbitration, and cleanup ledger

### Root causes

- Restart constructed a default configuration and unconditionally appended an attempt, so an
  interrupted override was lost and the audit log gained a second attempt.
- Pipeline-owned ready completion occurred before the runner entered its finalizing phase,
  leaving an await-sized cancellation race.
- Attempt success and job readiness were two independent writes.
- An unscoped runner discovered media-import rows.
- Source deletion failure was caught as if processing failed, despite the Dictation and job
  already being committed successfully.

### RED

Focused command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'RecoveryRetryTests|LocalJobRunnerTests|TranscriptionJobStoreTests|DatabaseMigrationTests'
```

Result: exit 1 with expected missing APIs and metadata, including
`latestUnfinishedAttempt`, `completeAttemptAndMarkJobReady`, `needsSourceCleanup`,
optional retry configuration, and the runner `kind` scope.

### Changes

- Migration 4 adds `needs_source_cleanup` and `source_cleanup_error`, including a populated
  version-3 upgrade regression.
- Restart reads the latest unfinished attempt and reuses its exact persisted language/model/
  template configuration, even when a conflicting override is supplied. No new attempt is
  created.
- `CancellationToken.beginFinalization()` calls back into the runner actor. Token cancellation
  check and the `executing` to `finalizing` phase flip occur in one actor turn before any
  completion await. Cancellation before it wins; cancellation after it returns `tooLate`.
- `completeAttemptAndMarkJobReady` commits attempt success, ready state, and cleanup-needed
  metadata in one `BEGIN IMMEDIATE` transaction; any failed predicate rolls back both writes.
- Recovery launch and resume are scoped to `.recovery`, and wrong-kind enqueue is ignored.
- Cleanup happens only after the atomic ready commit. Failure keeps the ready/succeeded state,
  retains the WAV, and records an explicit cleanup error. Launch retries cleanup; success removes
  the exact owned UUID WAV and clears both metadata fields.

### Verification

```text
make test && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release && git diff --check
```

Result: exit 0; 50 tests in 5 suites passed, the release build completed, and the diff check
produced no output.

### Concerns

None.
