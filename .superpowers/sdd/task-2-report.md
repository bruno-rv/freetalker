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

- Launch resumes persisted queued recoveries with default attempt configuration. A later retry UI can pass explicit overrides directly to `RecoveryRetryPipeline`; no override-selection UI is part of this task.
