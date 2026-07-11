# Local Jobs Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore durable tests and add the actor-isolated SQLite/job foundation shared by recovery and media imports.

**Architecture:** A dedicated `TranscriptionJobStore` actor owns its SQLite connection and migrations. A serial `LocalJobRunner` owns job execution and cooperative cancellation; UI observes it through a separate `@MainActor` façade.

**Tech Stack:** Swift 6.3, SQLite C API, Swift Testing, Foundation concurrency.

## Global Constraints

- All workflow content and processing stays local on this Mac.
- SQLite handles never cross actor boundaries.
- Interrupted `processing` jobs become `queued` at launch.
- Tests use temporary files/databases and no network, models, real screen, or pasteboard.
- Keep tests in the repository while their production behavior exists.

---

### Task 1: Restore the test target and database migrations

**Files:**
- Modify: `Package.swift`
- Modify: `Makefile`
- Create: `Sources/FreeTalker/Storage/DatabaseMigrations.swift`
- Create: `Tests/FreeTalkerTests/DatabaseMigrationTests.swift`

**Interfaces:**
- Produces: `DatabaseMigrator.migrate(_ db: OpaquePointer) throws`
- Produces: schema tables `transcription_jobs`, `job_attempts`, `speaker_segments`, `speaker_names`, `snippets`

- [ ] **Step 1: Add a failing migration test**

```swift
@Test func migratesEmptyDatabaseToLatestSchema() throws {
    let db = try TemporaryDatabase()
    try DatabaseMigrator.migrate(db.handle)
    #expect(try db.tableNames().isSuperset(of: [
        "transcription_jobs", "job_attempts", "speaker_segments",
        "speaker_names", "snippets", "schema_migrations"
    ]))
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter DatabaseMigrationTests`
Expected: FAIL because `DatabaseMigrator` and the test target do not exist.

- [ ] **Step 3: Add `.testTarget(name: "FreeTalkerTests", dependencies: ["FreeTalker"])`, restore `make test`, and implement idempotent numbered migrations**

```swift
enum DatabaseMigrator {
    static let latestVersion = 1
    static func migrate(_ db: OpaquePointer) throws
}
```

Migration 1 must create all five tables, indexes on job state/expiry and attempts/job ID, and record version 1 in one transaction.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter DatabaseMigrationTests && git diff --check`
Expected: PASS, including a second migration call with no schema changes.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Makefile Sources/FreeTalker/Storage/DatabaseMigrations.swift Tests/FreeTalkerTests/DatabaseMigrationTests.swift
git commit -m "test: restore durable workflow tests"
```

### Task 2: Add job domain models and actor store

**Files:**
- Create: `Sources/FreeTalker/Models/TranscriptionJob.swift`
- Create: `Sources/FreeTalker/Models/SpeakerSegment.swift`
- Create: `Sources/FreeTalker/Storage/TranscriptionJobStore.swift`
- Create: `Tests/FreeTalkerTests/TranscriptionJobStoreTests.swift`

**Interfaces:**
- Produces: `JobKind`, `JobState`, `JobStage`, `JobFailure`, `TranscriptionJob`, `JobAttempt`
- Produces: `actor TranscriptionJobStore`

- [ ] **Step 1: Write failing CRUD/state tests** covering create, legal transition, illegal transition, attempt append, restart recovery, and transactional speaker rename.

```swift
let job = try await store.create(kind: .recovery, source: source, now: clock.now)
try await store.transition(job.id, from: .queued, to: .processing(stage: .transcribing))
await #expect(throws: JobStoreError.invalidTransition) {
    try await store.transition(job.id, from: .processing, to: .queued)
}
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter TranscriptionJobStoreTests`
Expected: FAIL with missing job types/store.

- [ ] **Step 3: Implement minimal actor-owned persistence**

```swift
actor TranscriptionJobStore {
    init(databaseURL: URL, clock: any JobClock) throws
    func create(kind: JobKind, source: JobSource, now: Date) throws -> TranscriptionJob
    func job(id: UUID) throws -> TranscriptionJob?
    func jobs(kind: JobKind?) throws -> [TranscriptionJob]
    func transition(_ id: UUID, from: JobState.Kind, to: JobState) throws
    func beginAttempt(jobID: UUID, configuration: AttemptConfiguration) throws -> JobAttempt
    func finishAttempt(_ id: UUID, result: AttemptResult) throws
    func recoverInterruptedJobs() throws -> Int
    func replaceSpeakerName(jobID: UUID, speakerID: String, name: String) throws
}
```

Use one SQLite connection created and accessed only inside the actor. Encode enums explicitly, not through fragile case-description strings.

- [ ] **Step 4: Verify GREEN**

Run: `swift test --filter TranscriptionJobStoreTests`
Expected: PASS with temporary databases only.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeTalker/Models Sources/FreeTalker/Storage/TranscriptionJobStore.swift Tests/FreeTalkerTests/TranscriptionJobStoreTests.swift
git commit -m "feat: add durable transcription jobs"
```

### Task 3: Add the serial job runner and UI façade

**Files:**
- Create: `Sources/FreeTalker/Workflows/LocalJobRunner.swift`
- Create: `Sources/FreeTalker/Storage/JobLibraryStore.swift`
- Create: `Tests/FreeTalkerTests/LocalJobRunnerTests.swift`

**Interfaces:**
- Produces: `actor LocalJobRunner`
- Produces: `@MainActor final class JobLibraryStore: ObservableObject`

- [ ] **Step 1: Write failing serialization/restart/cancellation tests** using a suspended fake executor and deterministic event log.

```swift
await runner.enqueue(first.id)
await runner.enqueue(second.id)
#expect(await probe.maximumConcurrentExecutions == 1)
await runner.cancel(second.id)
#expect(try await store.job(id: second.id)?.state == .cancelled)
```

- [ ] **Step 2: Verify RED**

Run: `swift test --filter LocalJobRunnerTests`
Expected: FAIL because runner/façade are missing.

- [ ] **Step 3: Implement the runner without detached tasks**

```swift
actor LocalJobRunner {
    typealias Executor = @Sendable (TranscriptionJob, CancellationToken) async throws -> Void
    func enqueue(_ id: UUID) async
    func cancel(_ id: UUID) async
    func resumeQueuedJobs() async
}
```

The runner reads the job fresh before executing, changes stage transactionally, and checks cancellation between stages. `JobLibraryStore.refresh()` maps actor data to published recovery/import arrays on MainActor.

- [ ] **Step 4: Verify GREEN and full foundation**

Run: `swift test && swift build -c release && git diff --check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeTalker/Workflows Sources/FreeTalker/Storage/JobLibraryStore.swift Tests/FreeTalkerTests/LocalJobRunnerTests.swift
git commit -m "feat: add serial local job runner"
```

