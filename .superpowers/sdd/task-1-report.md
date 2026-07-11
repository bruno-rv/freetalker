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

## Review follow-up: database-first purge claims and path containment

### Root cause

The original retention flow read eligible rows, mutated the filesystem, and only then
conditionally deleted the database row. A job could become retryable between the read and
filesystem mutation, and a crash during the temporary rename protocol could leave an
untracked staged file. Lexical standardization also did not reject a symlinked source whose
resolved target was outside the recovery root. Capture rollback discarded a second failure
from deleting the final WAV.

### RED

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryStorageTests
```

Result: exit 1 with expected missing claim and compound-error APIs, including:

```text
error: cannot find type 'RecoveryPurgeClaim' in scope
error: cannot find type 'RecoveryCaptureRollbackError' in scope
error: value of type 'TranscriptionJobStore' has no member 'claimExpiredRecoveries'
error: value of type 'TranscriptionJobStore' has no member 'claimedRecoveries'
```

The first GREEN attempt exposed an invalid failure fixture: macOS recursively removes a
non-empty directory. That focused run failed 2 tests. The fixture was replaced by an injected
remover that fails deterministically while the service still operates on real temporary files
and SQLite.

### GREEN

Focused commands:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryStorageTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DatabaseMigrationTests
```

Results: exit 0; 14 recovery tests (including four parameterized retention cases) and 6
migration tests passed.

### Full verification

Command:

```text
make test && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release && git diff --check
```

Result: exit 0; 36 tests in 4 suites passed, the release build completed, and
`git diff --check` produced no output.

### Changes and self-review

- Migration 3 persists `purge_claimed_at` and `purge_error`, with an index for launch/purge
  reconciliation.
- One SQLite `UPDATE ... RETURNING` atomically claims only unclaimed, expired, failed recovery
  rows. No filesystem operation occurs before that statement completes.
- Transitions and attempt creation reject claimed rows, so retry/local-runner activation cannot
  race a claimed deletion.
- Purge first reconciles persistent claims, even under `never`: an existing file is removed then
  its row is deleted; an absent file proceeds directly to row deletion.
- Removal failures persist a cleanup error and retain the claimed row for a later retry.
- Cleanup deletes the exact source directly without rename staging. Conditional row deletion
  requires ID, recovery kind, failed state, claim presence, and exact source reference.
- Containment requires both a lexical UUID `.wav` direct child and a resolved direct child of
  the resolved recovery root. Tests cover `..`, nesting, symlink files, and a symlink root.
- Capture now throws `RecoveryCaptureRollbackError` containing both the persistence error and
  final-file rollback error when both operations fail.
- Crash reconciliation is verified after opening a new store connection against the same
  temporary SQLite database.

### Concerns

None.
