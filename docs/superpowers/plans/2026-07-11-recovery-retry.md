# Recovery and Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn failed captured audio into a visible, durable recovery inbox with safe retry and configurable cleanup.

**Architecture:** `RecoveryCaptureService` atomically owns WAV persistence, `RecoveryRetryPipeline` uses the shared job runner, and `RecoveryRetentionService` performs exact expiry cleanup. Library UI reads `JobLibraryStore`.

**Tech Stack:** Swift concurrency, SQLite job store, AVFoundation playback, SwiftUI.

## Global Constraints

- Default retention is exactly 7 days; options are 1, 7, 30, 90 days, or never.
- Source audio is deleted only after Dictation persistence and ready transition succeed.
- Retry is local and may choose a different downloaded speech model/template.
- Cleanup never deletes queued, processing, ready, or unexpired jobs.

---

### Task 1: Atomic recovery capture and retention

**Files:**
- Create: `Sources/FreeTalker/Workflows/Recovery/RecoveryCaptureService.swift`
- Create: `Sources/FreeTalker/Workflows/Recovery/RecoveryRetentionService.swift`
- Modify: `Sources/FreeTalker/Settings/AppSettings.swift`
- Test: `Tests/FreeTalkerTests/RecoveryStorageTests.swift`

- [ ] **Step 1: Write failing tests** for temp-write/rename, DB failure rollback, every retention value, exact-path deletion, and active-job exclusion.
- [ ] **Step 2: Run `swift test --filter RecoveryStorageTests` and confirm missing-service RED.**
- [ ] **Step 3: Implement:**

```swift
struct RecoveryCaptureService {
    func preserve(samples: [Float], metadata: RecoveryMetadata) async throws -> UUID
}
struct RecoveryRetentionService {
    func purgeExpired(now: Date, retention: RecoveryRetention) async throws -> PurgeResult
}
enum RecoveryRetention: Int, CaseIterable { case oneDay = 1, sevenDays = 7, thirtyDays = 30, ninetyDays = 90, never = -1 }
```

Write WAV to a UUID temporary file, fsync/close, rename to final URL, then create the job. Remove the final file if job creation fails.
- [ ] **Step 4: Run focused tests GREEN.**
- [ ] **Step 5: Commit `feat: preserve failed dictations for recovery`.**

### Task 2: Retry pipeline and AppCoordinator integration

**Files:**
- Create: `Sources/FreeTalker/Workflows/Recovery/RecoveryRetryPipeline.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Sources/FreeTalker/App.swift`
- Test: `Tests/FreeTalkerTests/RecoveryRetryTests.swift`

- [ ] **Step 1: Write failing tests** proving one attempt per retry, model/template override, raw transcript persistence on post-process failure, source preservation on DB failure, and interrupted retry recovery.
- [ ] **Step 2: Run focused test RED.**
- [ ] **Step 3: Implement pipeline:**

```swift
struct RecoveryRetryPipeline {
    func execute(jobID: UUID, configuration: AttemptConfiguration, cancellation: CancellationToken) async throws
}
```

Replace `saveFailedAudio` in `AppCoordinator` with `RecoveryCaptureService.preserve`. On success: record Dictation, mark job ready, then remove owned WAV in that order. Launch calls `recoverInterruptedJobs`, purge, and `resumeQueuedJobs`.
- [ ] **Step 4: Run `swift test --filter RecoveryRetryTests && swift build -c release` GREEN.**
- [ ] **Step 5: Commit `feat: retry recovered dictations`.**

### Task 3: Recovery Library UI

**Files:**
- Modify: `Sources/FreeTalker/UI/LibraryView.swift`
- Create: `Sources/FreeTalker/UI/RecoveriesView.swift`
- Create: `Sources/FreeTalker/UI/RecoveryRetrySheet.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Modify: `README.md`
- Test: `Tests/FreeTalkerTests/RecoveryPresentationTests.swift`

- [ ] **Step 1: Write failing pure presentation tests** for badge, expiry text, row actions, retry states, confirmation, and retention labels.
- [ ] **Step 2: Run focused test RED.**
- [ ] **Step 3: Add Dictations/Recoveries/Imports picker, recovery rows, playback, retry sheet, delete confirmation, and Settings retention picker.** UI actions call façade APIs only.
- [ ] **Step 4: Document local-only recovery and run `swift test && make app && git diff --check`.**
- [ ] **Step 5: Commit `feat: add recovery inbox`.**

