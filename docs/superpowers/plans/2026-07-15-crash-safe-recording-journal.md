# Crash-Safe Recording Journal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep every accepted non-empty external or Scratchpad recording in at
least one durable journal, visible Recovery, or capture-identified Library row
through crashes and downstream failures.

**Architecture:** A capture ledger and bounded segmented PCM journal become
durable before AVAudioEngine starts. Idempotent capture IDs bridge the file
system, recovery database, and Library database; temporary overlap is allowed,
and per-item reconciliation advances interrupted transitions without deleting
the final recoverable copy.

**Tech Stack:** Swift 6.2, AVFoundation, CryptoKit, Darwin file APIs, system
SQLite, Swift Testing, macOS 26.

## Global constraints

- Cover external dictation and Scratchpad recording; keep Voice Edit transient.
- Preserve explicit Escape or Cancel as intentional discard with crash-safe
  cleanup.
- Create and synchronize durable capture identity before starting audio.
- Keep at least one durable representation throughout every transition.
- Allow temporary Recovery and Library overlap across separate databases.
- Use a unique capture ID to prevent duplicate visible Library dictations.
- Perform no disk or SQLite I/O on the real-time audio callback.
- Use a bounded queue; never silently drop audio and continue.
- Store journal audio inside the existing FreeTalker Application Support
  privacy boundary.
- Keep diagnostic metadata free of audio samples and transcript text.
- Synchronize files, parent directories, and SQLite with full durability while
  describing power-loss survival as best effort.
- Keep the final recoverable audio until Library commit or explicit deletion.
- Do not restart or stop recording from acoustic silence alone.
- Persist completely silent attempts as visible non-retryable Recoveries.
- Reconcile artifacts independently so one corrupt item cannot stop later
  items.
- Add no package dependency.

---

### Task 1: Add durable journal file-system primitives

**Files:**

- Create:
  `Sources/FreeTalker/Workflows/Recovery/JournalFileSystem.swift`
- Create: `Tests/FreeTalkerTests/JournalFileSystemTests.swift`

**Interfaces:**

- Consumes: Foundation `FileHandle`, Darwin `rename`, `fsync`, and
  `F_FULLFSYNC`.
- Produces: `JournalFileSystem`, `LocalJournalFileSystem`, and
  `JournalPersistenceError`.

- [ ] **Step 1: Write failing operation-order and fault tests**

Create a recording fake in `JournalFileSystemTests.swift` and assert the
required atomic commit sequence:

```swift
@Test("atomic commit syncs file before rename and parent after")
func atomicCommitOrder() throws {
    let fs = RecordingJournalFileSystem()
    let writer = DurableArtifactWriter(fileSystem: fs)

    try writer.commit(Data([1, 2, 3]),
                      temporary: URL(fileURLWithPath: "/journal/1.tmp"),
                      destination: URL(fileURLWithPath: "/journal/1.pcm"))

    #expect(fs.events == [
        .write("/journal/1.tmp"),
        .synchronizeFile("/journal/1.tmp"),
        .rename("/journal/1.tmp", "/journal/1.pcm"),
        .synchronizeDirectory("/journal")
    ])
}
```

Parameterize a second test over write, file-sync, rename, and directory-sync
boundaries. Inject `ENOSPC`, `EACCES`, and `EIO`; assert the first error returns
and no later operation executes.

- [ ] **Step 2: Run the focused test and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter JournalFileSystemTests
```

Expected: compilation fails because the file-system interfaces do not exist.

- [ ] **Step 3: Implement file and directory durability primitives**

Create:

```swift
protocol JournalFileSystem: Sendable {
    func createDirectory(_ url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func synchronizeFile(_ url: URL) throws
    func rename(_ source: URL, to destination: URL) throws
    func synchronizeDirectory(_ url: URL) throws
    func contents(_ url: URL) throws -> [URL]
    func read(_ url: URL) throws -> Data
    func remove(_ url: URL) throws
    func exists(_ url: URL) -> Bool
}

struct DurableArtifactWriter: Sendable {
    let fileSystem: any JournalFileSystem

    func commit(_ data: Data, temporary: URL,
                destination: URL) throws {
        try fileSystem.write(data, to: temporary)
        try fileSystem.synchronizeFile(temporary)
        try fileSystem.rename(temporary, to: destination)
        try fileSystem.synchronizeDirectory(
            destination.deletingLastPathComponent()
        )
    }
}
```

`LocalJournalFileSystem.rename` uses same-directory `Darwin.rename`.
`synchronizeFile` and `synchronizeDirectory` open descriptors, attempt
`F_FULLFSYNC`, fall back to `fsync` only when unsupported, check return codes,
and close descriptors through `defer`.

Define concrete failures rather than returning raw integer codes:

```swift
enum JournalPersistenceError: Error, Equatable {
    case createDirectory(path: String, code: Int32)
    case write(path: String, code: Int32)
    case synchronizeFile(path: String, code: Int32)
    case rename(source: String, destination: String, code: Int32)
    case synchronizeDirectory(path: String, code: Int32)
    case read(path: String, code: Int32)
    case remove(path: String, code: Int32)
}
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all ordering and injected-failure cases pass.

- [ ] **Step 5: Commit the durability primitive**

```bash
git add Sources/FreeTalker/Workflows/Recovery/JournalFileSystem.swift \
  Tests/FreeTalkerTests/JournalFileSystemTests.swift
git commit -m "feat: add durable recovery filesystem primitives"
```

---

### Task 2: Add capture ledger and idempotent Library identity

**Files:**

- Create: `Sources/FreeTalker/Models/CaptureSession.swift`
- Create: `Sources/FreeTalker/Storage/CaptureSessionStore.swift`
- Create: `Tests/FreeTalkerTests/CaptureSessionStoreTests.swift`
- Create: `Tests/FreeTalkerTests/LibraryCaptureIdentityTests.swift`
- Modify: `Sources/FreeTalker/Storage/DatabaseMigrations.swift`
- Modify: `Sources/FreeTalker/Storage/TranscriptionJobStore.swift`
- Modify: `Sources/FreeTalker/Models/Dictation.swift`
- Modify: `Sources/FreeTalker/Storage/Database.swift`
- Modify: `Sources/FreeTalker/Storage/LibraryStore.swift`
- Modify: `Tests/FreeTalkerTests/DatabaseMigrationTests.swift`

**Interfaces:**

- Consumes: current schema version 10, `jobs.db`, `library.db`, and existing
  dictation insertion.
- Produces: schema version 11, `CaptureSession`, `CaptureSegment`,
  `CaptureLedgerStoring`, and unique nullable `dictations.capture_id`.

- [ ] **Step 1: Write failing migration and idempotency tests**

Add migration tests that open version-10 fixtures for both databases, migrate,
and assert existing rows remain. Re-run migration and assert no schema or data
change.

Create Library identity tests:

```swift
@Test("one capture identity creates one Library dictation")
func duplicateCaptureInsertIsIdempotent() async throws {
    let store = try LibraryStore.temporary()
    let captureID = UUID()

    let first = try await store.record(sampleDictation,
                                       captureID: captureID)
    let second = try await store.record(sampleDictation,
                                        captureID: captureID)

    #expect(first.id == second.id)
    #expect(try await store.dictations(captureID: captureID).count == 1)
}
```

Create ledger tests for idempotent legal transitions, rejected backward
transitions, ordered committed segments, and reopening unfinished sessions.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter \
'DatabaseMigrationTests|CaptureSessionStoreTests|LibraryCaptureIdentityTests'
```

Expected: compilation or assertions fail because version 11, ledger tables, and
capture identity do not exist.

- [ ] **Step 3: Add capture models and ledger interface**

Create:

```swift
enum CaptureSessionState: String, Codable, Sendable {
    case capturing, staged, processing
    case libraryCommitted = "library_committed"
    case silent, damaged, cancelling
}

enum RecoveryAssetKind: String, Codable, Sendable {
    case audio, silent, damaged, quarantined
}

struct CaptureSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let state: CaptureSessionState
    let directory: URL
    let capturedAt: Date
    let sampleRate: Double
    let channelCount: Int
    let inputDeviceUID: String?
    let destination: String
    let recoveryJobID: UUID?
    let libraryDictationID: Int64?
    let assetKind: RecoveryAssetKind
    let failureMessage: String?
    let contentHash: String?
}

struct CaptureSegment: Sendable, Equatable {
    let captureID: UUID
    let ordinal: Int
    let url: URL
    let sampleCount: Int
    let contentHash: String
}

struct CaptureStartRequest: Sendable, Equatable {
    let id: UUID
    let directory: URL
    let capturedAt: Date
    let sampleRate: Double
    let channelCount: Int
    let inputDeviceUID: String?
    let destination: String
}
```

Define the complete ledger boundary and implement it in a focused
`TranscriptionJobStore` extension:

```swift
protocol CaptureLedgerStoring: Sendable {
    func createCapture(_ request: CaptureStartRequest) async throws
        -> CaptureSession
    func recordCommittedSegment(_ segment: CaptureSegment) async throws
    func transition(
        id: UUID,
        from: CaptureSessionState,
        to: CaptureSessionState,
        recoveryJobID: UUID?,
        libraryDictationID: Int64?,
        assetKind: RecoveryAssetKind,
        failureMessage: String?,
        contentHash: String?
    ) async throws
    func session(id: UUID) async throws -> CaptureSession?
    func unfinishedSessions() async throws -> [CaptureSession]
    func committedSegments(captureID: UUID) async throws
        -> [CaptureSegment]
    func removeCleanedSession(id: UUID) async throws
}
```

- [ ] **Step 4: Add migration 11 and idempotent Library insertion**

Create `capture_sessions` and `capture_segments` with a composite
`(capture_id, ordinal)` key and cascading foreign key. Add nullable
`capture_id TEXT` to `dictations` and:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS idx_dictations_capture_id
ON dictations(capture_id)
WHERE capture_id IS NOT NULL;
```

Make migration 11 conditional and idempotent because the shared migrator runs
against both database files.

Add `captureID: UUID?` to `Dictation`, and change Library APIs to
`record(_:captureID: UUID? = nil)`. Insert with conflict avoidance, then select
the existing row by capture ID and return it without overwriting user edits.

- [ ] **Step 5: Run focused and complete storage tests**

Run the Step 2 command, then:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'DatabaseTests|LibraryStoreTests|TranscriptionJobStoreTests'
```

Expected: migrations, ledger transitions, and Library identity tests pass.

- [ ] **Step 6: Commit the capture ledger**

```bash
git add Sources/FreeTalker/Models/CaptureSession.swift \
  Sources/FreeTalker/Storage/CaptureSessionStore.swift \
  Sources/FreeTalker/Storage/DatabaseMigrations.swift \
  Sources/FreeTalker/Storage/TranscriptionJobStore.swift \
  Sources/FreeTalker/Models/Dictation.swift \
  Sources/FreeTalker/Storage/Database.swift \
  Sources/FreeTalker/Storage/LibraryStore.swift \
  Tests/FreeTalkerTests/CaptureSessionStoreTests.swift \
  Tests/FreeTalkerTests/LibraryCaptureIdentityTests.swift \
  Tests/FreeTalkerTests/DatabaseMigrationTests.swift
git commit -m "feat: add capture ledger and idempotent library identity"
```

---

### Task 3: Journal active audio in bounded durable segments

**Files:**

- Create:
  `Sources/FreeTalker/Workflows/Recovery/CaptureSegmentCodec.swift`
- Create:
  `Sources/FreeTalker/Workflows/Recovery/CaptureJournalWriter.swift`
- Create:
  `Sources/FreeTalker/Workflows/Recovery/CaptureJournalService.swift`
- Create: `Tests/FreeTalkerTests/CaptureJournalWriterTests.swift`
- Create: `Tests/FreeTalkerTests/CaptureJournalFaultTests.swift`

**Interfaces:**

- Consumes: `JournalFileSystem`, `CaptureLedgerStoring`, 16-kHz mono Float32
  samples, and capture session directories.
- Produces: `CaptureJournalWriter`, `CaptureJournalService`,
  `ActiveCaptureJournal`, and `StagedCapture`.

- [ ] **Step 1: Write failing segmentation and recovery tests**

Test exactly 8,000 frames, a final partial segment, ordered assembly, truncated
or reordered data, duplicate ordinals, hash mismatch, queue overflow, and
writer re-creation after each persistence boundary.

```swift
@Test("eight thousand frames commit one segment")
func segmentBoundary() async throws {
    let fixture = try await JournalWriterFixture(segmentFrames: 8_000)
    #expect(fixture.writer.enqueue(Array(repeating: 0.25,
                                         count: 8_000)) == .accepted)
    let staged = try await fixture.writer.finish()

    #expect(staged.segments.count == 1)
    #expect(staged.segments[0].sampleCount == 8_000)
    #expect(try fixture.codec.decode(staged.segments[0].url).count == 8_000)
}
```

Assert overflow returns `.overflow`, invokes failure once, and rejects later
buffers instead of silently accepting them.

- [ ] **Step 2: Run journal tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'CaptureJournalWriterTests|CaptureJournalFaultTests'
```

Expected: compilation fails because journal types do not exist.

- [ ] **Step 3: Implement segment codec and bounded writer**

Implement independent 16-kHz mono Float32 WAV segments with ordinal,
sample-count, and SHA-256 validation. Create:

```swift
final class CaptureJournalWriter: @unchecked Sendable {
    struct Configuration: Sendable {
        let segmentFrames: Int
        let maximumQueuedFrames: Int

        static let `default` = Configuration(
            segmentFrames: 8_000,
            maximumQueuedFrames: 128_000
        )
    }

    enum EnqueueResult: Equatable {
        case accepted
        case overflow
        case failed(String)
    }

    nonisolated func enqueue(_ samples: [Float]) -> EnqueueResult
    func finish() async throws -> StagedCapture
    func committedSnapshot() async -> [CaptureSegment]
}
```

The nonisolated call copies into a lock-protected bounded queue only. A serial
worker encodes, atomically commits, and records each segment. After overflow or
failure, reject subsequent buffers and notify the coordinator exactly once.

Use these lifecycle values across the writer, service, and later tasks:

```swift
struct CaptureDiagnostics: Sendable, Equatable, Codable {
    let peak: Float
    let rms: Float
    let inputDeviceUID: String?
    let routeFailure: String?
}

struct ActiveCaptureJournal: @unchecked Sendable {
    let session: CaptureSession
    let writer: CaptureJournalWriter
}

struct StagedCapture: Sendable, Equatable {
    let captureID: UUID
    let canonicalAudioURL: URL
    let segments: [CaptureSegment]
    let sampleCount: Int
    let diagnostics: CaptureDiagnostics
}
```

- [ ] **Step 4: Implement journal lifecycle service**

Create:

```swift
struct CaptureJournalService: Sendable {
    func prepare(_ request: CaptureStartRequest) async throws
        -> ActiveCaptureJournal
    func finish(_ active: ActiveCaptureJournal) async throws -> StagedCapture
    func recordSilent(_ active: ActiveCaptureJournal,
                      diagnostics: CaptureDiagnostics) async throws
    func cancelAndClean(_ active: ActiveCaptureJournal) async throws
    func markProcessing(captureID: UUID,
                        recoveryJobID: UUID) async throws
    func markLibraryCommitted(captureID: UUID,
                              dictationID: Int64) async throws
    func resumeCleanup(captureID: UUID) async throws
}
```

`finish` drains buffers, commits the final segment, assembles and synchronizes
one canonical UUID WAV without deleting segments, and transitions to `staged`.
Cancellation first transitions to `cancelling`, removes artifacts, and deletes
the ledger row last.

- [ ] **Step 5: Run focused, sustained, and fault tests**

Run the Step 2 command. Include a sustained synthetic recording that proves
queued frames stay at or below 128,000. Expected: all cases pass.

- [ ] **Step 6: Commit the segmented journal**

```bash
git add Sources/FreeTalker/Workflows/Recovery/CaptureSegmentCodec.swift \
  Sources/FreeTalker/Workflows/Recovery/CaptureJournalWriter.swift \
  Sources/FreeTalker/Workflows/Recovery/CaptureJournalService.swift \
  Tests/FreeTalkerTests/CaptureJournalWriterTests.swift \
  Tests/FreeTalkerTests/CaptureJournalFaultTests.swift
git commit -m "feat: journal active capture audio in durable segments"
```

---

### Task 4: Admit recording only after durable journal setup

**Files:**

- Create: `Sources/FreeTalker/Core/CaptureAdmissionReducer.swift`
- Create: `Tests/FreeTalkerTests/CaptureAdmissionTests.swift`
- Modify: `Sources/FreeTalker/Core/AudioCapture.swift`
- Modify: `Sources/FreeTalker/Core/RecordingStateMachine.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Tests/FreeTalkerTests/AudioCaptureDecisionTests.swift`
- Modify: `Tests/FreeTalkerTests/RecordingDestinationTests.swift`
- Modify: `Tests/FreeTalkerTests/ScratchpadRecordingTests.swift`

**Interfaces:**

- Consumes: `CaptureJournalService.prepare`, `CaptureJournalWriter`, external
  and Scratchpad destination state, key-up, and Escape events.
- Produces: pending admission state and AudioCapture sample-consumer hooks.

- [ ] **Step 1: Write failing admission-order and early-event tests**

Use ordered spies to assert:

```swift
@Test("engine starts only after durable preparation")
func preparationPrecedesAudio() async throws {
    let fixture = AdmissionFixture()
    await fixture.coordinator.beginExternalRecording()
    #expect(fixture.events == [
        .createDirectory, .createLedger, .synchronizeDirectory,
        .startAudioEngine
    ])
}
```

Add tests where key-up or Escape arrives while preparation is suspended.
Key-up finishes immediately after start; Escape records cancellation intent and
cleans without starting processing. Preparation failure must not start audio.

- [ ] **Step 2: Run admission tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter \
'CaptureAdmissionTests|RecordingDestinationTests|ScratchpadRecordingTests'
```

Expected: new order assertions fail because audio currently starts before a
durable active journal exists.

- [ ] **Step 3: Extend AudioCapture without adding callback I/O**

Change `AudioCapture.start` to:

```swift
func start(
    deviceUID: String?,
    noiseSuppression: Bool,
    sampleConsumer: (@Sendable ([Float])
        -> CaptureJournalWriter.EnqueueResult)? = nil,
    onConsumerFailure: (@Sendable (
        CaptureJournalWriter.EnqueueResult
    ) -> Void)? = nil
) throws
```

After conversion, copy samples to the bounded consumer. Schedule failure
handling off the tap callback. Keep the current in-memory sample buffer during
this project so transcription, preview, and transient Voice Edit remain
source-compatible.

- [ ] **Step 4: Implement asynchronous admission reducer**

Create states `idle`, `preparing`, `recording`, and `cancelling`. Record key-up
and Escape events received during `preparing`; do not block the main actor with
a semaphore. `AppCoordinator` awaits `journalService.prepare`, then starts
AudioCapture only on success and only for external or Scratchpad workflows.

Use an explicit reducer contract:

```swift
enum CaptureAdmissionState: Equatable {
    case idle
    case preparing(destination: String, stopRequested: Bool,
                   cancelRequested: Bool)
    case recording(captureID: UUID)
    case cancelling(captureID: UUID)
}

enum CaptureAdmissionEvent: Equatable {
    case begin(destination: String)
    case prepared(captureID: UUID)
    case preparationFailed(String)
    case stopRequested
    case cancelRequested
    case cleanupFinished
}
```

On Stop: stop audio, drain journal, classify silent versus audio, stage the
canonical WAV, then start processing. On Escape: persist `cancelling`, clean
artifacts, and remove the ledger last.

- [ ] **Step 5: Run destination, audio, and admission suites**

Run the Step 2 command and
`--filter AudioCaptureDecisionTests`. Expected: all pass without main-actor
blocking or unbounded callback work.

- [ ] **Step 6: Commit durable admission**

```bash
git add Sources/FreeTalker/Core/CaptureAdmissionReducer.swift \
  Sources/FreeTalker/Core/AudioCapture.swift \
  Sources/FreeTalker/Core/RecordingStateMachine.swift \
  Sources/FreeTalker/AppCoordinator.swift \
  Tests/FreeTalkerTests/CaptureAdmissionTests.swift \
  Tests/FreeTalkerTests/AudioCaptureDecisionTests.swift \
  Tests/FreeTalkerTests/RecordingDestinationTests.swift \
  Tests/FreeTalkerTests/ScratchpadRecordingTests.swift
git commit -m "feat: admit recordings only after durable journal setup"
```

---

### Task 5: Make processing and cleanup idempotent

**Files:**

- Modify:
  `Sources/FreeTalker/Workflows/Recovery/RecoveryCaptureService.swift`
- Modify:
  `Sources/FreeTalker/Workflows/Recovery/RecoveryRetryPipeline.swift`
- Modify: `Sources/FreeTalker/Storage/RecoveryLeaseStore.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Tests/FreeTalkerTests/RecoveryStorageTests.swift`
- Modify: `Tests/FreeTalkerTests/RecoveryRetryTests.swift`

**Interfaces:**

- Consumes: capture-ID Library insertion and capture ledger.
- Produces: forward-only Library commit and resumable cleanup order.

- [ ] **Step 1: Write failing crash-boundary tests**

For every arrow in this order, inject a failure and reopen stores:

```text
Library insert(captureID)
→ ledger libraryCommitted(libraryID)
→ delete canonical WAV and segments
→ synchronize session directory
→ delete recovery job
→ delete capture-session row
```

Assert the capture remains in Recovery or Library after each reopen, repeated
retry creates one Library row, and no transcription runs after Library commit.

- [ ] **Step 2: Run recovery tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecoveryStorageTests|RecoveryRetryTests'
```

Expected: crash-order cases fail because current completion deletes the
recovery row before audio.

- [ ] **Step 3: Implement forward-only processing and cleanup**

Pass capture ID into foreground and recovered Library writes. Replace
delete-row-first completion with the exact tested order. On restart, query the
Library by capture ID first; when found, record `libraryCommitted` and resume
cleanup without transcription.

Every cleanup operation is idempotent: missing already-deleted media counts as
complete only when a Library row with the capture ID exists. Keep temporary
Recovery/Library overlap until media and job cleanup succeed.

- [ ] **Step 4: Run recovery and Library identity tests**

Run Step 2 plus `--filter LibraryCaptureIdentityTests`. Expected: all pass.

- [ ] **Step 5: Commit idempotent finalization**

```bash
git add Sources/FreeTalker/Workflows/Recovery/RecoveryCaptureService.swift \
  Sources/FreeTalker/Workflows/Recovery/RecoveryRetryPipeline.swift \
  Sources/FreeTalker/Storage/RecoveryLeaseStore.swift \
  Sources/FreeTalker/AppCoordinator.swift \
  Tests/FreeTalkerTests/RecoveryStorageTests.swift \
  Tests/FreeTalkerTests/RecoveryRetryTests.swift
git commit -m "fix: finalize recovery captures without losing ownership"
```

---

### Task 6: Reconcile every artifact and import legacy audio

**Files:**

- Create:
  `Sources/FreeTalker/Workflows/Recovery/RecoveryReconciler.swift`
- Create:
  `Sources/FreeTalker/Workflows/Recovery/LegacyRecoveryImporter.swift`
- Create: `Sources/FreeTalker/Models/RecoveryReconciliationReport.swift`
- Create: `Tests/FreeTalkerTests/RecoveryReconciliationTests.swift`
- Create: `Tests/FreeTalkerTests/LegacyRecoveryImportTests.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`

**Interfaces:**

- Consumes: session directories, ledger rows, pending markers, current and
  legacy WAVs, Library capture IDs, and SHA-256.
- Produces: per-item reconciliation, quarantine, deduplicated migration, and
  same-session retry.

- [ ] **Step 1: Write failing inventory and isolation tests**

Create fixtures containing a valid active journal, committed marker, orphan
UUID WAV, two identical `failed-*.wav` files, corrupt WAV, Library-committed
capture, and a later valid item after a forced I/O error.

Assert the report counts imported, duplicate, quarantined, and failed items;
the later valid item still imports; no source moves before a durable row exists;
and running reconciliation twice creates no duplicates.

- [ ] **Step 2: Run reconciliation tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecoveryReconciliationTests|LegacyRecoveryImportTests'
```

Expected: compilation fails because reconciler and report types do not exist.

- [ ] **Step 3: Implement inventory, per-item recovery, and migration**

Inventory all approved artifact classes. Reconcile each inside its own
`do/catch`. Use capture ID first and SHA-256 for legacy files. Valid unindexed
audio becomes a visible recovery row; invalid audio becomes quarantined without
deleting the artifact. Never trust one marker pattern as the full inventory.

Use an injected retry scheduler with exact delays `0`, `250` milliseconds, and
`1` second for same-session registration failures.

Create a concrete report that remains stable across UI and tests:

```swift
struct RecoveryReconciliationReport: Sendable, Equatable {
    var imported = 0
    var duplicates = 0
    var quarantined = 0
    var failed = 0
    var failures: [RecoveryReconciliationFailure] = []
}

struct RecoveryReconciliationFailure: Sendable, Equatable {
    let artifact: URL
    let message: String
}
```

- [ ] **Step 4: Surface launch reconciliation errors**

Replace blanket `try?` in the launch recovery path with a report published to
the coordinator. A store-wide error becomes recovery health failure; item-level
errors remain in the report and do not abort the loop.

- [ ] **Step 5: Run reconciliation and existing recovery tests**

Run Step 2 plus
`--filter 'RecoveryStorageTests|RecoveryRetryTests'`. Expected: all pass.

- [ ] **Step 6: Commit reconciliation and migration**

```bash
git add Sources/FreeTalker/Workflows/Recovery/RecoveryReconciler.swift \
  Sources/FreeTalker/Workflows/Recovery/LegacyRecoveryImporter.swift \
  Sources/FreeTalker/Models/RecoveryReconciliationReport.swift \
  Sources/FreeTalker/AppCoordinator.swift \
  Tests/FreeTalkerTests/RecoveryReconciliationTests.swift \
  Tests/FreeTalkerTests/LegacyRecoveryImportTests.swift
git commit -m "feat: reconcile interrupted and legacy recovery artifacts"
```

---

### Task 7: Surface recovery health and silent capture attempts

**Files:**

- Create: `Sources/FreeTalker/Models/RecoveryHealth.swift`
- Create: `Tests/FreeTalkerTests/RecoveryHealthTests.swift`
- Create: `Tests/FreeTalkerTests/MicrophoneSignalWatchdogTests.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Sources/FreeTalker/App.swift`
- Modify: `Sources/FreeTalker/Core/AudioCapture.swift`
- Modify: `Sources/FreeTalker/UI/LibraryView.swift`

**Interfaces:**

- Consumes: recovery-store initialization, reconciliation report, incremental
  peak and RMS, and engine or route faults.
- Produces: `RecoveryHealth`, recording admission gate, initial-silence warning,
  and visible silent capture state.

- [ ] **Step 1: Write failing health and signal tests**

Test:

```swift
enum RecoveryHealth: Equatable {
    case initializing
    case healthy
    case degraded(String)
    case unavailable(String)
}
```

Assert recording is blocked for `initializing` and `unavailable`. Allow
`degraded` only when journal admission storage remains healthy.

Signal tests cover initial zero samples producing a warning without restart,
valid signal followed by silence producing no warning, corroborated route fault
causing one restart, and all-silent Stop producing a visible silent session
with exact message **No microphone signal was captured**.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecoveryHealthTests|MicrophoneSignalWatchdogTests'
```

Expected: compilation fails because health and watchdog state do not exist.

- [ ] **Step 3: Implement health state and admission gate**

Publish `RecoveryHealth` from coordinator initialization and reconciliation.
Remove durability-boundary `try?`. Add a persistent menu and Library warning
with the stored failure message and **Retry Recovery Setup** action. Refuse new
external or Scratchpad recording while admission storage is unavailable.

- [ ] **Step 4: Implement safe signal behavior**

Track peak and RMS incrementally. Once valid signal exceeds the existing
`1e-7` floor, never classify that capture as silent. During initial all-zero
input, warn but continue. Restart once only when AudioCapture also reports an
engine or input-route fault. At Stop, store a silent session with no audio retry
when the entire attempt remains below the floor.

Implement the decision logic as a pure testable value:

```swift
struct MicrophoneSignalWatchdog: Sendable {
    enum Decision: Equatable {
        case continueRecording
        case warnNoSignal
        case restartForRouteFailure
    }

    mutating func observe(peak: Float, rms: Float,
                          routeFailure: String?) -> Decision
}
```

- [ ] **Step 5: Run health, signal, and admission tests**

Run Step 2 plus `--filter CaptureAdmissionTests`. Expected: all pass.

- [ ] **Step 6: Commit health and silent capture behavior**

```bash
git add Sources/FreeTalker/Models/RecoveryHealth.swift \
  Sources/FreeTalker/AppCoordinator.swift Sources/FreeTalker/App.swift \
  Sources/FreeTalker/Core/AudioCapture.swift \
  Sources/FreeTalker/UI/LibraryView.swift \
  Tests/FreeTalkerTests/RecoveryHealthTests.swift \
  Tests/FreeTalkerTests/MicrophoneSignalWatchdogTests.swift
git commit -m "feat: surface recovery health and silent captures"
```

---

### Task 8: Add explicit Recovery actions and correct retention

**Files:**

- Create: `Sources/FreeTalker/Models/RecoveryItem.swift`
- Create: `Tests/FreeTalkerTests/RecoveryPresentationTests.swift`
- Modify: `Sources/FreeTalker/Storage/JobLibraryStore.swift`
- Modify: `Sources/FreeTalker/UI/RecoveriesView.swift`
- Modify: `Sources/FreeTalker/UI/RecoveryRetrySheet.swift`
- Modify: `Sources/FreeTalker/Storage/RecoveryRetentionService.swift`
- Modify: `Sources/FreeTalker/Storage/LibraryStore.swift`
- Modify: `Tests/FreeTalkerTests/RecoveryStorageTests.swift`

**Interfaces:**

- Consumes: capture sessions, optional jobs and audio, Library commit state,
  and explicit user actions.
- Produces: `RecoveryItem`, state-specific action sets, export, and retention
  that never removes the final retryable copy.

- [ ] **Step 1: Write failing presentation and retention tests**

Create:

```swift
enum RecoveryAction: Hashable, Sendable {
    case retryProcessing
    case exportAudio
    case exportArtifact
    case startNewRecording
    case delete
}

struct RecoveryItem: Identifiable, Equatable {
    let id: UUID
    let job: TranscriptionJob?
    let session: CaptureSession
    let audioURL: URL?
    let availableActions: Set<RecoveryAction>
}
```

Assert audio items expose Retry, Export, and Delete; silent items expose Start
New Recording and Delete; damaged items expose Export Artifact when possible
and Delete; processing items disallow concurrent Retry.

Seed failed recovery audio, run retention and Library Delete All, and assert the
final audio still exists. Seed `libraryCommitted` cleanup artifacts and assert
retention may remove those.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'RecoveryPresentationTests|RecoveryStorageTests'
```

Expected: new action tests fail and existing cleanup deletes retryable files.

- [ ] **Step 3: Implement Recovery projection and actions**

Join session, optional transcription job, and audio into `RecoveryItem`.
Render action sets by asset and state. Use `NSSavePanel` in the view, then call
`JobLibraryStore.export(id:to:)` to copy without moving the source. Silent rows
show the exact failure and **Start New Recording**, never **Retry Processing**.

- [ ] **Step 4: Remove destructive automatic retention paths**

Stop `LibraryStore.purgeDebugAudio` and **Delete All** from deleting recovery
audio. Restrict automatic recovery retention to `libraryCommitted` cleanup.
Failed, retryable, damaged, and quarantined assets require explicit deletion.

- [ ] **Step 5: Run focused and Library tests**

Run Step 2 plus `--filter LibraryStoreTests`. Expected: actions and retention
rules pass.

- [ ] **Step 6: Commit Recovery actions and retention correction**

```bash
git add Sources/FreeTalker/Models/RecoveryItem.swift \
  Sources/FreeTalker/Storage/JobLibraryStore.swift \
  Sources/FreeTalker/UI/RecoveriesView.swift \
  Sources/FreeTalker/UI/RecoveryRetrySheet.swift \
  Sources/FreeTalker/Storage/RecoveryRetentionService.swift \
  Sources/FreeTalker/Storage/LibraryStore.swift \
  Tests/FreeTalkerTests/RecoveryPresentationTests.swift \
  Tests/FreeTalkerTests/RecoveryStorageTests.swift
git commit -m "feat: add explicit recovery actions and preserve final audio"
```

---

### Task 9: Verify the complete recording durability matrix

**Files:**

- Create: `Tests/FreeTalkerTests/RecordingDurabilityInvariantTests.swift`
- Create: `docs/testing/recording-durability-smoke-test.md`

**Interfaces:**

- Consumes: journal, ledger, Library identity, reconciliation, health, actions,
  and injected failures from Tasks 1 through 8.
- Produces: complete automated invariant evidence and a repeatable real-device
  smoke protocol.

- [ ] **Step 1: Write the cross-component invariant harness**

For every failure boundary, discard all live objects, reopen temporary
directories and both databases, run reconciliation, and assert:

```swift
let durableCount =
    (activeJournalExists ? 1 : 0) +
    (visibleRecoveryExists ? 1 : 0) +
    (libraryCaptureExists ? 1 : 0)
#expect(durableCount >= 1)
#expect(libraryRowsForCapture <= 1)
```

Cover segment write, file sync, rename, directory sync, segment ledger update,
WAV assembly, staged transition, job creation, Library insert,
`libraryCommitted`, media deletion, job deletion, and ledger deletion. Add
SQLite busy, open, and corruption failures plus one corrupt artifact followed
by a valid one.

- [ ] **Step 2: Run invariant tests and observe any RED boundary**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter RecordingDurabilityInvariantTests
```

Expected before final integration corrections: any uncovered boundary fails
with a named transition where durable count becomes zero or duplicate Library
rows appear.

- [ ] **Step 3: Escalate each reproduced invariant failure**

If a named boundary fails, preserve the test and report the exact boundary and
owning task to the controller. The controller inserts a focused fix task against
the owning source file and re-runs task review before Task 9 continues. Do not
weaken `durableCount >= 1` or the unique Library assertion inside this task.

- [ ] **Step 4: Write the manual smoke protocol**

Document exact steps for real microphone input, initial silence warning,
force-quit during active recording, force-quit during processing, relaunch,
Recovery retry/export/delete, silent attempt visibility, legacy import summary,
disk-full simulation, secondary Scratchpad flow, and explicit Escape cleanup.
State that Voice Edit is transient and outside the durability guarantee.

- [ ] **Step 5: Run complete automated verification**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build -c release
make app
git diff --check
```

Expected: all tests and release build pass with no diff errors.

- [ ] **Step 6: Perform the real-device smoke protocol**

Run every step in `docs/testing/recording-durability-smoke-test.md`. Confirm
every non-empty external or Scratchpad capture is in at least one durable state,
silent attempts are visible, and explicit cancellation reconciles cleanup.

- [ ] **Step 7: Commit final invariant coverage and reproduced fixes**

```bash
git add Tests/FreeTalkerTests/RecordingDurabilityInvariantTests.swift \
  docs/testing/recording-durability-smoke-test.md
git add -u Sources/FreeTalker Tests/FreeTalkerTests
git commit -m "test: verify recording durability across failure boundaries"
```
