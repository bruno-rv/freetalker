# Recording durability real-device smoke test

Use this protocol on a disposable test account or test Mac before release. It
complements the automated fault matrix; it does not replace it. FreeTalker uses
full file and SQLite synchronization, but survival of sudden power loss remains
best effort within macOS, the file system, and storage-hardware guarantees. The
current in-memory microphone buffer can also be lost before it becomes a
confirmed journal segment.

## Prerequisites and evidence

1. Quit FreeTalker and create an isolated APFS sparse image. These commands
   create at most a 1 GiB image in the named file; they never fill the system
   disk intentionally:

   ```zsh
   IMAGE="$HOME/FreeTalkerSmoke.sparseimage"
   hdiutil create -size 1g -type SPARSE -fs APFS \
     -volname FreeTalkerSmoke "$IMAGE"
   hdiutil attach "$IMAGE" -mountpoint /Volumes/FreeTalkerSmoke
   mkdir -m 700 /Volumes/FreeTalkerSmoke/session
   ```

2. Build and launch the DEBUG executable with both isolation opt-ins. Release
   builds ignore these variables, relative paths fail closed, and roots outside
   a mounted `/Volumes/...` volume fail closed:

   ```zsh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
   env FREETALKER_ALLOW_ISOLATED_SMOKE=1 \
     FREETALKER_SMOKE_ROOT=/Volumes/FreeTalkerSmoke/session \
     .build/debug/FreeTalker &
   APP_PID=$!
   ```

3. Verify isolation before recording. Stop immediately if either database is
   outside the sparse image:

   ```zsh
   lsof -p "$APP_PID" | grep '/Volumes/FreeTalkerSmoke/session'
   test -e /Volumes/FreeTalkerSmoke/session/jobs.db
   test -e /Volumes/FreeTalkerSmoke/session/library.db
   sqlite3 /Volumes/FreeTalkerSmoke/session/jobs.db '.databases'
   sqlite3 /Volumes/FreeTalkerSmoke/session/library.db '.databases'
   ```

4. Back up both isolated databases before lock/corruption tests, after quitting
   the app cleanly:

   ```zsh
   kill "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
   sqlite3 /Volumes/FreeTalkerSmoke/session/jobs.db \
     ".backup '/Volumes/FreeTalkerSmoke/jobs.backup.db'"
   sqlite3 /Volumes/FreeTalkerSmoke/session/library.db \
     ".backup '/Volumes/FreeTalkerSmoke/library.backup.db'"
   ```
3. Connect a known-good microphone. In System Settings, confirm FreeTalker has
   Microphone and Accessibility permission.
4. Open **Library → Recoveries** and note its initial rows. Record the app
   version, macOS version, input device, destination, timestamps, and screenshots
   before and after every relaunch.
5. For each capture, save its Recovery message, exported file hash and duration,
   Library row count, and any recovery-health message. A non-empty accepted
   External or Scratchpad capture must always have at least one owner: active
   journal evidence, a visible Recovery, or one Library row.

## Signal and normal-capture checks

1. Start an External recording, speak clearly for at least five seconds (more
   than one journal segment), stop, and confirm exactly one Library item.
2. Start another recording and remain silent through the initial observation
   window. Confirm the no-signal warning appears but recording neither stops nor
   restarts from silence alone. Stop while still silent. Confirm Recoveries shows
   **No microphone signal was captured.**, Start New Recording, and Delete, but
   not Retry Processing.
3. Speak clearly first, then remain silent. Stop and confirm the valid beginning
   remains processable; the later silence must not reclassify the capture as a
   silent attempt.
4. If safe and practical, disconnect or switch the input route during a capture.
   Record the resulting diagnostics. A corroborated route/engine fault may cause
   at most one restart; silence by itself must not. Route faults are hardware-
   and macOS-dependent and are not claimed to be reliably reproducible manually.

## Force-quit and relaunch checks

For every force-quit, use Activity Monitor or `kill -9` only after the stated
boundary. Do not press Cancel or Escape first.

1. Start External recording, speak for at least five seconds, and force-quit
   while recording. Relaunch. Confirm the capture is visible in Recoveries and
   can be retried or exported, or is already present exactly once in Library.
2. Repeat with Scratchpad. Confirm the same ownership invariant and that a
   successful retry restores the intended Scratchpad result.
3. For repeatable processing boundaries, launch the isolated DEBUG executable
   under LLDB and set regex breakpoints on real functions (no hidden pause hook
   is assumed):

   ```zsh
   lldb .build/debug/FreeTalker
   (lldb) settings set target.env-vars FREETALKER_ALLOW_ISOLATED_SMOKE=1 FREETALKER_SMOKE_ROOT=/Volumes/FreeTalkerSmoke/session
   (lldb) breakpoint set -r 'RecoveryRetryPipeline.*execute'
   (lldb) breakpoint set -r 'RecoveryCaptureService.*completeJournalCapture'
   (lldb) breakpoint set -r 'RecoveryCaptureService.*cleanupLibraryCommittedSession'
   (lldb) run
   ```

   When the chosen breakpoint stops, obtain the exact process ID with
   `process status`, then terminate from a second Terminal only after verifying
   there is exactly one FreeTalker process:

   ```zsh
   PIDS=($(pgrep -x FreeTalker))
   (( ${#PIDS[@]} == 1 )) || { print -u2 'refusing ambiguous kill'; exit 1; }
   kill -9 "$PIDS[1]"
   ```

   Repeat after job creation/lease, Library insert, `libraryCommitted`, and
   cleanup. If symbol breakpoints are unavailable, mark the stage **not
   executed** rather than estimating timing.
4. Launch FreeTalker twice during recovery setup. Confirm setup/reconciliation is
   single-flight, the stale runner stops, and one visible result remains.

## Recovery actions and ownership

1. On a valid Recovery, choose Retry Processing. Relaunch once during retry if a
   deterministic test hook is available. Confirm one Library row at most.
2. Export a valid Recovery to a new destination. Verify the exported WAV opens,
   has non-zero duration and audible content, and record its SHA-256 hash.
3. Delete the source Recovery. Confirm the independently exported copy remains
   readable and unchanged.
4. On a damaged/quarantined row, confirm only safe actions are offered. Export
   Artifact must never expose an outside-root or symbolic-link target.
5. Delete a recoverable row and relaunch during cleanup if a pause hook exists.
   Confirm durable disposition/claim intent prevents resurrection. Confirm
   automatic retention never removes the last recoverable copy.

## Legacy and orphan inventory

On the disposable profile, place these fixtures in `failed-dictations`: a valid
PCM16 `failed-*.wav`, a valid UUID-named orphan WAV, a preparation/failure
marker, and one corrupt WAV followed lexically by another valid WAV. Relaunch.

Confirm the import summary reports imported, duplicate, invalid/quarantined,
and failed counts accurately; the corrupt artifact remains visible/quarantined
and does not prevent the later valid file from importing. Relaunch again and
confirm content-hash and lineage deduplication creates no duplicate row.

## Disk-full and health checks

1. Never fill the system disk. Confirm `FREETALKER_SMOKE_ROOT` resolves to the
   attached sparse image as above. Exhaust only its free space with a removable
   filler, leaving the Terminal session available:

   ```zsh
   FILL=/Volumes/FreeTalkerSmoke/fill.bin
   FREE_KB=$(df -k /Volumes/FreeTalkerSmoke | awk 'NR==2 {print $4}')
   (( FREE_KB > 16384 )) || { print -u2 'disposable volume too small'; exit 1; }
   mkfile "$((FREE_KB - 8192))k" "$FILL"
   ```

   Remove the filler immediately after the expected error with `rm -f "$FILL"`.
2. Exhaust only that disposable volume during segment persistence and again
   during final assembly. Confirm recording stops visibly, committed evidence is
   retained, and relaunch reports an actionable unavailable/degraded state.
3. Test a real locked jobs database by keeping this interactive transaction open
   in Terminal A while attempting recording in the app, then type `ROLLBACK;`:

   ```zsh
   sqlite3 /Volumes/FreeTalkerSmoke/session/jobs.db
   sqlite> BEGIN EXCLUSIVE;
   sqlite> SELECT count(*) FROM capture_sessions;
   # attempt recording in FreeTalker now
   sqlite> ROLLBACK;
   ```

   Confirm the first admission is blocked and Retry Recovery Setup succeeds
   after rollback.
   Confirm External and Scratchpad admission is blocked while health is
   unavailable, the exact operation is shown, and Retry Recovery Setup recovers
   after access is restored.
4. On the isolated copy only, corrupt the jobs store after a force-quit, then
   restore the SQLite backup. Never run these commands against `~/Library`:

   ```zsh
   printf 'corrupt-test-only\n' > /Volumes/FreeTalkerSmoke/session/jobs.db
   rm -f /Volumes/FreeTalkerSmoke/session/jobs.db-{wal,shm}
   # relaunch, capture the unavailable-health evidence, quit again
   cp /Volumes/FreeTalkerSmoke/jobs.backup.db \
     /Volumes/FreeTalkerSmoke/session/jobs.db
   chmod 600 /Volumes/FreeTalkerSmoke/session/jobs.db
   ```

   On disposable copies only, corrupt one store/artifact. Confirm store-wide
   failure reports unavailable and blocks admission; item-local corruption is
   quarantined without deleting other evidence. Do not expect recovery from a
   wholly destroyed database when no filesystem evidence exists.

## Explicit cancellation

1. Start External recording, speak past one segment, press Escape/Cancel, and
   immediately relaunch during cleanup if a test hook exists. Confirm the
   persisted cancellation intent resumes and neither Recovery nor Library
   resurrects the intentionally discarded capture.
2. Repeat in Scratchpad.
3. Voice Edit is intentionally transient and is outside this durability
   guarantee; Escape/Cancel there discards the edit workflow as designed.

## Pass criteria

- Every accepted non-empty External and Scratchpad capture is always represented
  by journal evidence, visible Recovery, or exactly one Library row.
- No Library identity has more than one row and no capture is retranscribed after
  its Library row exists.
- Silent attempts remain visible with the exact explanation and no misleading
  Retry Processing action.
- Retry, Export, Delete, retention, legacy import, health retry, and explicit
  cancellation converge after relaunch without deleting an uncommitted last copy.
- Record unexecuted hardware- or hook-dependent steps explicitly; do not report
  this protocol as passed unless every required executable step was observed.

Finally quit FreeTalker, remove only the test image, and detach it:

```zsh
PIDS=($(pgrep -x FreeTalker))
(( ${#PIDS[@]} == 0 )) || { print -u2 'quit FreeTalker before detach'; exit 1; }
hdiutil detach /Volumes/FreeTalkerSmoke
rm -f "$HOME/FreeTalkerSmoke.sparseimage"
```
