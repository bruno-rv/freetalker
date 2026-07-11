# Task 1 report: atomic recovery capture and retention

## Status

DONE

## Changes

- Added `RecoveryCaptureService`, which writes a UUID temporary WAV, synchronizes and closes it, renames it to its final UUID `.wav`, and then creates one failed recovery job.
- Added rollback that removes both temporary and final files when file or job persistence fails.
- Added `RecoveryRetentionService` with 1, 7, 30, and 90 day boundaries plus never retention.
- Restricted cleanup to expired failed recovery jobs and exact UUID-named `.wav` direct children of the configured recovery directory.
- Staged files before conditional database deletion so a failed or stale delete restores the source.
- Added actor-preserving recovery store operations and persisted `AppSettings.recoveryRetention` with a seven-day default.
- Added real temporary-directory and SQLite coverage for atomic capture, database rollback, every retention value, exact path safety, and state/kind exclusions.

## TDD evidence

### RED

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryStorageTests
```

Result: exit 1 with the expected missing-production-type failures, including:

```text
error: cannot find 'RecoveryRetention' in scope
error: cannot find type 'RecoveryJobStoring' in scope
error: cannot find 'RecoveryCaptureService' in scope
error: cannot find 'RecoveryRetentionService' in scope
```

### GREEN

Focused command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryStorageTests
```

Result: exit 0; 6 tests in `RecoveryStorageTests` passed, including four parameterized retention cases.

### Full verification

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release && git diff --check
```

Result: exit 0; 28 tests in 4 suites passed, the release build completed, and `git diff --check` produced no output.

## Self-review

- File durability order is temporary write, `synchronize`, close, rename, then database create.
- Recovery creation is one SQLite insert in the terminal failed state; no intermediate queued/processing row can survive.
- Store access remains actor-isolated behind async protocol requirements; SQLite handles and statements are not exposed.
- Cleanup eligibility requires recovery kind, failed state, and an inclusive age boundary. Never retention returns before reading or mutating the store.
- Conditional deletion repeats kind, state, ID, and exact source reference checks at mutation time, preventing stale reads from deleting active work.
- Path validation rejects nested paths, prefix matches, wrong extensions, and non-UUID filenames. Sibling files remain untouched.
- A conditional database deletion failure restores the staged WAV before propagating the error.

## Concerns

None.
