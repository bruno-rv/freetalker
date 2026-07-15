# Crash-Safe Recording Journal Design

Date: 2026-07-15
Status: Approved 2026-07-15

## Objective

Guarantee that every accepted recording containing audio is always represented
by one durable state: an active capture journal, a visible retryable Recovery,
or a committed Library dictation.

Silent capture attempts must remain visible with a specific explanation rather
than disappearing without a trace.

## Background

The current recovery flow durably stages valid audio after recording stops and
protects it from downstream cancellation, transcription, translation, and
Library failures. It does not journal audio during active recording. A crash,
force quit, or power loss before staging can therefore lose the whole capture.

The reported July 15 incident produced a 0.489-second WAV whose samples were
all zero. Current code correctly rejects that file as non-transcriptable but
does so before recovery registration. The result is neither a Library item nor
a visible Recovery.

The local recovery directory also contains legacy WAV files without current
database records. Startup reconciliation scans only committed marker files, so
those recordings remain invisible.

## Durability invariant

For every capture identity, exactly one of these states owns the latest
recoverable representation:

```text
capturing journal
    -> staged recovery
    -> processing recovery
    -> Library committed
    -> cleaned
```

A transition may be retried after interruption. It must not create duplicate
Library dictations, discard the last audio copy, or leave the capture absent
from both the journal and durable stores.

Sudden power loss may discard samples still inside the current in-memory audio
buffer. Every fully committed journal segment and the capture's durable ledger
record must survive.

## Capture identity and ledger

Before FreeTalker accepts a recording start, it:

1. Opens and validates the recovery database.
2. Creates a UUID capture-session directory.
3. Inserts a `capturing` ledger row with the capture ID, timestamps, audio
   format, input device identity, selected context, and journal path.
4. Synchronizes the database, directory, and required parent metadata.
5. Starts the audio engine only after those operations succeed.

If any operation fails, FreeTalker does not begin recording. It presents a
persistent recovery-health message with the failing operation and a retry
action.

The Library and recovery stores use the capture ID as an idempotency key.
Repeated reconciliation or processing cannot create a second dictation for the
same capture.

## Audio journal

The real-time audio callback must not perform file I/O. It copies PCM buffers
into a bounded queue owned by a dedicated journal writer.

The writer:

- Encodes sequential, independently recoverable PCM segments.
- Writes each segment to a temporary file in the session directory.
- Synchronizes file contents before atomically renaming the segment.
- Synchronizes the parent directory after the rename.
- Updates durable segment metadata idempotently.
- Applies bounded backpressure and fails the active recording visibly instead
  of silently dropping buffers.

On Stop, the writer drains the queue, commits the final partial segment, and
marks the session `staged`. Downstream processing reads only committed segments
and treats their ordered composition as the recording source.

Segment duration must balance write overhead and loss exposure. The
implementation plan will select the shortest interval that passes sustained
recording and fault-injection performance tests. The invariant does not depend
on one exact interval.

## Microphone signal watchdog

The capture path measures signal energy without retaining a second audio copy.
If committed audio remains effectively silent during the initial observation
window, FreeTalker:

1. Records input-device and route diagnostics.
2. Restarts the capture engine once.
3. Ends the attempt if the restarted engine still produces no signal.
4. Keeps a visible failed-capture row stating **No microphone signal was
   captured**.

The failed row provides **Start New Recording** and diagnostic detail. It does
not provide **Retry Processing** because no transcriptable audio exists.

The watchdog must not classify ordinary pauses as failure after valid signal
has been observed. Existing captured-audio quality checks remain a final guard.

## Recovery states and user experience

**Library → Recoveries** displays:

- Interrupted active journals discovered after relaunch.
- Staged and processing recordings.
- Downstream failures that retain audio.
- Imported legacy or orphaned recordings.
- Silent capture attempts with no retryable audio.

Recoverable audio rows provide **Retry Processing**, **Export Audio**, and
**Delete**. Silent rows provide **Start New Recording** and **Delete**.

FreeTalker never deletes the final recoverable audio copy automatically. After
the Library transaction commits, the recovery row first records
`libraryCommitted` with the Library identifier. Cleanup then deletes journal
segments and recovery media. Removing the completed recovery row is the final
step. A cleanup interruption remains idempotently resumable.

## Startup reconciliation

Startup reconciliation inventories owned artifacts instead of trusting a
single marker pattern. It compares:

- Capture-session directories and committed segments.
- Recovery database rows.
- Pending markers from the existing recovery flow.
- Unindexed current-format audio.
- Legacy `failed-*.wav` recordings.
- Library rows carrying capture IDs.

Each item reconciles inside its own error boundary. One corrupt file, database
row, or I/O error cannot stop later items. Failures remain visible with enough
detail to export or delete the affected artifact.

Legacy and orphaned audio imports use a content hash and source metadata to
avoid duplicates. The first migration summarizes imported, duplicate, invalid,
and failed items. Invalid artifacts move to a visible quarantine state rather
than disappearing.

## Same-session recovery

Failures that previously required relaunch, such as database registration
after marker creation, enter a bounded same-session retry queue. Retry uses the
same idempotent capture ID and never creates a second recovery row.

The app surfaces persistent recovery-store initialization and reconciliation
failures. It does not use `try?` at durability boundaries.

## Failure handling

The system handles these failures explicitly:

- Audio queue overflow or journal-writer failure stops recording and preserves
  every committed segment.
- Disk-full and permission errors block or fail capture visibly.
- Database open, migration, transaction, or busy errors preserve journal
  artifacts and expose recovery health.
- File rename or directory-sync errors retain the temporary or committed
  artifact for reconciliation.
- Transcription, translation, and Library errors retain retryable recovery
  audio.
- Cleanup errors keep the `libraryCommitted` row until cleanup finishes.
- A missing artifact leaves a visible damaged entry with diagnostics rather
  than silently deleting its row.

## Privacy and retention

Journal audio stays inside FreeTalker's Application Support container and uses
the same local privacy boundary as current recovery audio. Diagnostic records
may include device identifiers and error metadata but must not include audio
samples or transcript text beyond existing user-visible recovery data.

Users can export or explicitly delete recovery audio. Existing retention
settings apply only after a durable Library commit or explicit deletion.

## Testing strategy

### State and idempotency tests

- Exercise every transition twice and verify one capture and one Library row.
- Restart from every intermediate state and verify forward reconciliation.
- Verify the invariant after every injected failure.

### Journal tests

- Recover committed segments after writer or process termination.
- Reject or quarantine truncated, reordered, duplicated, and corrupt segments.
- Verify queue backpressure never silently drops buffers.
- Verify file and directory synchronization order through an injected file
  system.
- Exercise sustained recordings long enough to expose queue or storage growth.

### Fault-injection tests

- Terminate between temporary write, file sync, rename, directory sync,
  database transition, Library commit, audio cleanup, and row cleanup.
- Inject disk-full, I/O, permission, and SQLite busy or corruption errors.
- Relaunch after each boundary and verify the capture is visible and recoverable
  or already committed to the Library.

### Watchdog tests

- Detect sustained zero-valued input and attempt one engine restart.
- Preserve a visible silent-capture result after repeated dead input.
- Avoid false failure after valid signal followed by silence.
- Preserve committed audio when the input route fails mid-recording.

### Migration and user-flow tests

- Import legacy and orphaned WAV files once by content hash.
- Continue reconciliation after one invalid artifact.
- Retry, export, and explicitly delete recoverable audio.
- Display silent captures without a misleading processing retry.
- Force quit during real recording and processing, relaunch, and recover from
  **Library → Recoveries**.

## Success criteria

The feature is complete when every accepted non-empty recording remains in an
active journal, visible Recovery, or committed Library item across crashes,
force quits, downstream failures, and tested power-loss boundaries. Silent
capture attempts remain visible with an accurate explanation. Existing legacy
and orphaned audio becomes discoverable without duplication, and no automatic
cleanup removes the final recoverable audio copy before durable Library commit.
