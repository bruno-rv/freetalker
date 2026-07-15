# Recording Task 9 Report

## Outcome

Implemented the persistent cross-component recording durability matrix requested
by review. Every case uses a real temporary recovery root, a real jobs SQLite
database, and a separate real Library SQLite database. Fault adapters forward to
the real filesystem/store, perform the named durable side effect, and then throw.
The producer scope returns before a fresh store, production `RecoveryReconciler`,
production `JobLibraryStore.refresh()`, and Library connection are created.

Evidence is deliberately strict:

- active journal evidence requires committed segment metadata plus an existing
  Float32 WAV whose identity, header, samples, count, and SHA-256 validate, or a
  recognized owned failure/preparation marker;
- visible Recovery evidence comes only from `JobLibraryStore.recoveryItems` and
  its production action/state projection;
- Library evidence comes only from rows queried by capture ID.

An empty directory, raw ledger row, hidden ready/cancelled job, or in-memory
object never counts.

## Strict TDD and reproduced invariant failures

The review correction began with new tests against the old approximation. RED
cycles established missing isolation and real persistent boundary adapters.
Two genuine product failures were then reproduced:

1. **Queue overflow durability:** a first buffer larger than the 128,000-frame
   bound latched only in RAM and notified the coordinator asynchronously; no
   durable failure marker existed. The regression required
   `capture-failure.marker`. `CaptureJournalWriter` now owns one awaitable
   marker-and-ledger persistence task, completes it before failure notification,
   and drains it from `finish` and `stop`, while keeping `enqueue` free of
   filesystem and SQLite I/O. Task publication and the failed state now occur
   under the same lock. A deterministic barrier test pauses persistence, races
   both `finish` and `stop`, and proves neither returns before marker, damaged
   ledger state, and the subsequently ordered notification are complete.
2. **Directory-create acknowledgement loss:** `createDirectory` could durably
   succeed and then throw before the preparation compensation boundary, leaving
   an unowned directory. `CaptureJournalService.prepare` now runs the same
   compensate-or-own protocol around directory creation as parent sync.

Both regressions failed for the exact missing durable effect before source was
changed, then passed with their owning focused suites.

## Persistent matrix

The parameterized ordinary post-side-effect matrix contains 19 named cases:

- preparation ledger commit with lost acknowledgement;
- segment write, file sync, rename, directory sync, and real segment-ledger
  commit;
- canonical file sync, rename, directory sync, and staged transition;
- recovery job create and processing link;
- Library insert durable-then-throw and `libraryCommitted` transition;
- canonical removal, segment removal, session directory sync, recovery-job
  durable delete, and ledger durable delete.

Overflow durability is a separate scenario that drains its owned persistence
operation before verification. Silent diagnostics commit, transition, segment
removal, directory sync, and segment-metadata delete run for both External and
Scratchpad (10 cases). Cancel intent, owned directory removal, parent sync, and
ledger delete also run for both destinations (8 cases) and require terminal zero
state after fresh reconciliation. The session-directory-sync injector records an
event trace and fires only for the exact capture directory after media removal.

Two additional preparation cases inject post-effect directory-create and parent-
sync failures before acceptance. They assert admission returns no active capture,
no ledger row remains, and compensation removes the directory.

The ordinary restart matrix separately covers External and Scratchpad at six
lifecycle states (12 cases); ordinary silent and cancellation convergence also
run in both destinations. Explicit cancellation allows zero owners only after
durable intent and clean terminal disposal. Pre-accept and stale-lease producers
release their original store connections before verification opens a fresh one.

## SQLite, projection, and concurrency evidence

- A real second SQLite connection holds `BEGIN EXCLUSIVE`; the jobs mutation
  fails, `ROLLBACK` releases it, and the exact mutation retry plus fresh
  reconciliation preserves the capture.
- A directory at the jobs database path fails open before admission.
- A temp-only jobs database is byte-corrupted after valid journal persistence.
  Open fails, owned WAV evidence remains decodable, the test restores its private
  backup, and fresh reconciliation recovers. No user database is touched.
- A corrupt legacy artifact preceding valid legacy PCM16 and UUID-orphan audio
  produces a durable damaged/quarantined production item with retained artifact,
  no Retry Processing, and no duplicate after a second reopen.
- Silent production projection has the exact message, only Start New Recording
  and Delete, no recovery job, and no Library row.
- A real stale processing lease is expired with a controlled store clock. The
  production `RecoveryRetryPipeline` finalizes a Library-owned capture across
  repeated reopen with zero sample loads and zero processing calls.

## Isolated smoke support

Added `FreeTalkerPaths`, a DEBUG-only fail-closed isolation seam shared by the
recovery root, jobs database, Library database, templates, snippets, Scratchpad,
media/debug paths, local model storage, and debug-audio purge. It requires both:

```text
FREETALKER_ALLOW_ISOLATED_SMOKE=1
FREETALKER_SMOKE_ROOT=/Volumes/<mounted-volume>/<absolute-path>
```

Release builds ignore the variables. In DEBUG, neither variable means an ordinary
production run. If either variable is present, partial or invalid configuration
never falls back to live data: typed resolution exposes a configuration error,
all app-owned paths resolve beneath a deliberately unusable `/dev/null` sentinel,
and recovery setup reports unavailable. Tests cover partial variables, relative
and traversing roots, fake directories, symlink components, and unmounted
`/Volumes` paths without creating the production directory. The mount check uses
macOS's mounted-volume inventory and exact volume containment.

The smoke document now includes executable `hdiutil` APFS sparse-image commands,
DEBUG launch and path verification, SQLite `.backup`, real exclusive lock,
temp-only corruption/restore, allocated disk-full filler on the disposable
image, stable DEBUG-only checkpoints after job creation, Library insert,
`libraryCommitted`, delete claim, and cancel intent, exact-one-PID force quit,
exact isolated relaunch verification, cleanup, and detach. Checkpoints require
the process's resolved Application Support root to equal the configured isolated
root. Fresh bootstrap waits for jobs storage with an asserted timeout, then tells
the operator to open Library before separately waiting for and verifying its lazy
database. No pre-initialization Library file handle is assumed. The release
executable exports no checkpoint symbol. Expected jobs-store corruption and
open-failure runs use a separate bounded unavailable-state verifier: it requires
exactly one launched DEBUG process, both isolation environment values, the real
mounted smoke root, no live production-path handles, and explicit confirmation
of the Recovery warning, Retry Recovery Setup, and Recoveries Unavailable UI.
The DEBUG executable is canonicalized once before launch, and that same resolved
path is used for direct launch, LLDB launch, and `lsof` text-vnode comparison so
SwiftPM's `.build/debug` symlink cannot cause a false mismatch.
It deliberately does not require a jobs database handle or successful SQLite
open. After removing WAL/SHM companions and restoring the SQLite backup, the
normal verifier is required again and the operator must confirm health recovery.

## Verification

```text
RecordingDurabilityInvariantTests: 17 tests; 19 ordinary post-effect cases,
  1 overflow scenario, 10 silent cases, 8 cancellation cases, 12 lifecycle
  cases, 2 ordinary destination flows, and 2 preparation cases passed
make test: exit 0 (749 listed tests)
swift build -c release: exit 0
release `nm` checkpoint-symbol absence: confirmed
make app: exit 0
codesign --verify --deep --strict --verbose=2 FreeTalker.app: exit 0
git diff --check: exit 0
```

The only warning is the pre-existing FluidAudio unhandled `benchmark.md`
resource warning.

The real microphone/manual protocol was not executed in this noninteractive
worker environment. The document requires operators to record unexecuted
hardware stages honestly. Voice Edit remains explicitly transient and outside
the durability guarantee; power-loss survival remains best effort within macOS,
filesystem, storage hardware, and the current uncommitted audio buffer.
