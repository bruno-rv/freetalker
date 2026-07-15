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

2. Build the DEBUG executable and define the only supported launch and isolation
   verification commands. Release builds ignore these variables, relative paths
   fail closed, and roots outside a real mounted `/Volumes/...` volume fail
   closed:

   ```zsh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
   SMOKE_ROOT=/Volumes/FreeTalkerSmoke/session
   wait_for_file() {
     local path="$1"
     for _ in {1..100}; do
       test -e "$path" && return 0
       sleep 0.1
     done
     print -u2 "timed out waiting for $path"
     return 1
   }
   launch_smoke() {
     env FREETALKER_ALLOW_ISOLATED_SMOKE=1 \
       FREETALKER_SMOKE_ROOT="$SMOKE_ROOT" \
       .build/debug/FreeTalker &
     APP_PID=$!
     kill -0 "$APP_PID" 2>/dev/null || return 1
     wait_for_file "$SMOKE_ROOT/jobs.db" || return 1
   }
   verify_jobs_root() {
     test "$(stat -f '%m' "$SMOKE_ROOT")" = /Volumes/FreeTalkerSmoke
     lsof -p "$APP_PID" | grep -F "$SMOKE_ROOT/jobs.db"
     sqlite3 "$SMOKE_ROOT/jobs.db" '.databases' | grep -F "$SMOKE_ROOT/jobs.db"
   }
   verify_library_root() {
     wait_for_file "$SMOKE_ROOT/library.db" || return 1
     sqlite3 "$SMOKE_ROOT/library.db" '.databases' | grep -F "$SMOKE_ROOT/library.db"
   }
   relaunch_and_verify() { launch_smoke && verify_jobs_root; }
   relaunch_and_verify || exit 1
   ```

3. The launch is invalid unless `verify_jobs_root` succeeds. On a fresh profile,
   `LibraryStore` creates `library.db` lazily: click the FreeTalker menu-bar icon,
   choose **Library**, wait for the Library window, then run:

   ```zsh
   verify_library_root || exit 1
   ```

   Stop immediately if either database is outside the sparse image. Run
   `relaunch_and_verify`
   after every clean quit or force-quit in this protocol; a bare `open`, direct
   executable launch, or Finder relaunch does not preserve isolation. After a
   fresh isolated root, repeat the explicit Library UI step and
   `verify_library_root || exit 1` before any Library assertion.

4. Back up both isolated databases before lock/corruption tests, after quitting
   the app cleanly, then perform the exact isolated relaunch and verification:

   ```zsh
   kill "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
   sqlite3 "$SMOKE_ROOT/jobs.db" ".backup '/Volumes/FreeTalkerSmoke/jobs.backup.db'"
   sqlite3 "$SMOKE_ROOT/library.db" ".backup '/Volumes/FreeTalkerSmoke/library.backup.db'"
   relaunch_and_verify
   ```

5. Connect a known-good microphone. In System Settings, confirm FreeTalker has
   Microphone and Accessibility permission.
6. Open **Library → Recoveries** and note its initial rows. Record the app
   version, macOS version, input device, destination, timestamps, and screenshots
   before and after every relaunch.
7. For each capture, save its Recovery message, exported file hash and duration,
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
3. For exact processing and cleanup boundaries, first quit the normally launched
   app, then launch the isolated DEBUG executable under LLDB using the stable
   DEBUG-only checkpoint symbol:

   ```zsh
   lldb .build/debug/FreeTalker
   (lldb) settings set target.env-vars FREETALKER_ALLOW_ISOLATED_SMOKE=1 FREETALKER_SMOKE_ROOT=/Volumes/FreeTalkerSmoke/session FREETALKER_SMOKE_CHECKPOINTS=post-job-create,post-library-insert,post-library-committed,delete-claim,cancel-intent
   (lldb) breakpoint set --name freetalker_smoke_checkpoint
   (lldb) run
   ```

   At each stop, use `frame variable name` to read the checkpoint C string.
   Continue until the named boundary under test, obtain the exact PID with
   `process status`, and terminate from a second Terminal only after verifying
   there is exactly one FreeTalker process:

   ```zsh
   PIDS=($(pgrep -x FreeTalker))
   (( ${#PIDS[@]} == 1 )) || { print -u2 'refusing ambiguous kill'; exit 1; }
   kill -9 "$PIDS[1]"
   ```

   Detach the dead LLDB process, then run `relaunch_and_verify` before inspecting
   Recoveries or Library. Repeat at `post-job-create`, `post-library-insert`,
   `post-library-committed`, `delete-claim`, and `cancel-intent`. The checkpoint
   is inert unless DEBUG isolation resolves to the exact configured root, and
   the symbol is absent from release builds.
4. Launch FreeTalker twice during recovery setup. Confirm setup/reconciliation is
   single-flight, the stale runner stops, and one visible result remains.

## Recovery actions and ownership

1. On a valid Recovery, choose Retry Processing. Stop at the
   `post-library-insert` checkpoint, kill the exact PID, then run
   `relaunch_and_verify`. Confirm one Library row at most.
2. Export a valid Recovery to a new destination. Verify the exported WAV opens,
   has non-zero duration and audible content, and record its SHA-256 hash.
3. Delete the source Recovery. Confirm the independently exported copy remains
   readable and unchanged.
4. On a damaged/quarantined row, confirm only safe actions are offered. Export
   Artifact must never expose an outside-root or symbolic-link target.
5. Delete a recoverable row. Stop at `delete-claim`, kill the exact PID, then run
   `relaunch_and_verify`. Confirm durable disposition/claim intent prevents
   resurrection. Confirm automatic retention never removes the last recoverable
   copy.

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
   kill -9 "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
   printf 'corrupt-test-only\n' > /Volumes/FreeTalkerSmoke/session/jobs.db
   rm -f /Volumes/FreeTalkerSmoke/session/jobs.db-{wal,shm}
   relaunch_and_verify
   # capture the unavailable-health evidence, then quit the isolated app
   kill "$APP_PID"; wait "$APP_PID" 2>/dev/null || true
   cp /Volumes/FreeTalkerSmoke/jobs.backup.db \
     /Volumes/FreeTalkerSmoke/session/jobs.db
   chmod 600 /Volumes/FreeTalkerSmoke/session/jobs.db
   relaunch_and_verify
   ```

   On disposable copies only, corrupt one store/artifact. Confirm store-wide
   failure reports unavailable and blocks admission; item-local corruption is
   quarantined without deleting other evidence. Do not expect recovery from a
   wholly destroyed database when no filesystem evidence exists.

## Explicit cancellation

1. Start External recording, speak past one segment, press Escape/Cancel, stop
   at `cancel-intent`, kill the exact PID, then run `relaunch_and_verify`.
   Confirm the persisted cancellation intent resumes and neither Recovery nor
   Library resurrects the intentionally discarded capture.
2. Repeat the same `cancel-intent` checkpoint, exact-PID kill, and
   `relaunch_and_verify` sequence in Scratchpad.
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
- Record unexecuted hardware-dependent steps explicitly; do not report
  this protocol as passed unless every required executable step was observed.

Finally quit FreeTalker, remove only the test image, and detach it:

```zsh
PIDS=($(pgrep -x FreeTalker))
(( ${#PIDS[@]} == 0 )) || { print -u2 'quit FreeTalker before detach'; exit 1; }
hdiutil detach /Volumes/FreeTalkerSmoke
rm -f "$HOME/FreeTalkerSmoke.sparseimage"
```
