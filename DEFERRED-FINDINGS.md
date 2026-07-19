# Deferred Findings (Codex adversarial review, round 7)

These findings from round 7 describe real flaws, but the flawed code is **byte-for-byte identical
to `main` (HEAD)** — the current voice-command-layer PR (PR-A) does not touch it, so fixing it here
would be scope creep onto a pre-existing recovery-subsystem issue, not a regression this PR
introduced. Each entry below has the diff evidence proving that, plus a suggested fix for a
dedicated follow-up PR.

---

## F1 — arbitrary-file deletion via ledger-persisted segment URLs

**Where:** `Sources/FreeTalker/Workflows/Recovery/RecoveryCaptureService.swift:306`

```swift
for segment in try await ledger.committedSegments(captureID: captureID) {
    if journalFileSystem.exists(segment.url) { try journalFileSystem.remove(segment.url) }
}
```

**Why pre-existing:** This exact loop (three lines, unchanged) sits in `cleanupLibraryCommittedSession`,
a method this PR *does* touch extensively (it adds `validateNestedSessionDirectoryOwnership` right
before this loop, plus new marker-cleanup and directory-removal blocks after it — see round-5/6
Codex-attributed comments in the same function). But this specific loop is not part of any diff
hunk:

```
$ git diff HEAD -- Sources/FreeTalker/Workflows/Recovery/RecoveryCaptureService.swift | grep -n '^@@'
5:@@ -42,7 +42,10 @@ ...
17:@@ -167,10 +170,14 @@ ...
33:@@ -263,6 +270,16 @@ ...   (adds validateNestedSessionDirectoryOwnership call)
50:@@ -292,6 +309,42 @@ ...   (adds marker-cleanup block, AFTER this loop)
93:@@ -306,6 +359,38 @@ ...   (adds directory-removal block, AFTER this loop)
```

`git show HEAD:...RecoveryCaptureService.swift` (i.e. `main`) contains the identical
`for segment in try await ledger.committedSegments(...)` loop at its pre-PR line 285-287, with no
validation of `segment.url` there either. The new `validateNestedSessionDirectoryOwnership` this PR
added only proves `session.directory` is exactly `<recoveryRoot>/<captureID>` — it says nothing
about the individual `segment.url` values recorded in the ledger, which is exactly the gap this
finding describes. The gap is real on `main` today, unmodified by this PR.

**Suggested fix (follow-up PR):** Before deleting `segment.url`, validate it the same way
`validateNestedSessionDirectoryOwnership` validates `session.directory`: require
`segment.url.deletingLastPathComponent()` to resolve (lexically and post-symlink) to
`session.directory`, and require the leaf to match the `segment-%08d.wav` pattern for the
segment's own recorded ordinal. This is now cheap to add given `validateNestedSessionDirectoryOwnership`
already exists in this file as a template.

---

## F2 — `RecoveryRetentionService` rejects legitimate shared-root legacy sessions before reconciliation

**Where:** `Sources/FreeTalker/Workflows/Recovery/RecoveryRetentionService.swift:95-112`
(`cleanupLibraryCommittedSessions`), called from `RecoveryReconciler.performReconciliation` (line
~64) *before* the per-session reconciliation loop runs, inside the same `do` block whose `catch`
aborts the entire pass via `report.storeFailure`.

**Why pre-existing:** The whole file has zero diff:

```
$ git diff HEAD -- Sources/FreeTalker/Workflows/Recovery/RecoveryRetentionService.swift | wc -l
0
```

And the call site in `RecoveryReconciler.performReconciliation` — the exact ordering (`purgeExpired`
before the session loop, both inside the same failure-propagating `do`/`catch`) — is also unchanged;
`git show HEAD:...RecoveryReconciler.swift` shows byte-identical code at that location. The two
files this scenario depends on for reaching a legacy shared-root `.libraryCommitted` session
(`LegacyRecoveryImporter.swift`, `RecoveryOwnershipMigrator.swift`) are also zero-diff:

```
$ git diff HEAD -- .../LegacyRecoveryImporter.swift .../RecoveryOwnershipMigrator.swift | wc -l
0
```

The only *new* code nearby is `RecoveryCaptureService.validateNestedSessionDirectoryOwnership`,
which explicitly documents and exempts the legacy `session.directory == directory` layout (line
~398: `guard session.directory.standardizedFileURL.path != directory.standardizedFileURL.path else
{ return }`). `RecoveryRetentionService.cleanupLibraryCommittedSessions` has no equivalent
exemption and never did — it unconditionally builds `expected = lexicalDirectory/<uuid>` and throws
`captureIdentityMismatch` for any `.libraryCommitted` session whose directory isn't that exact
nested path, legacy or not. This double standard is not something this PR created; it's a
pre-existing gap in `RecoveryRetentionService` that this PR's new (correctly legacy-aware) validator
elsewhere simply makes more visible by contrast.

**Suggested fix (follow-up PR):** Give `RecoveryRetentionService.cleanupLibraryCommittedSessions`
the same legacy exemption `RecoveryCaptureService.validateNestedSessionDirectoryOwnership` has, or
better, route both through one shared ownership-validation helper.

---

## F3 — restart bypasses `cleanupNotPermitted`, stranding a job

**Where:** `Sources/FreeTalker/Workflows/Recovery/RecoveryRetentionService.swift:109`
(`try await CaptureJournalService(fileSystem: fileSystem, ledger: ledger).resumeCleanup(captureID:
session.id)`), and the `resumeCleanup`/`cancelAndClean` implementation it calls in
`CaptureJournalService.swift`.

**Why pre-existing:** `RecoveryRetentionService.swift` is zero-diff (see F2 evidence above). This
PR's only change to `CaptureJournalService.swift` is additive — it introduces
`VoiceCommandFinalizationIntent` and a `voiceCommands:` parameter on `finish(_:voiceCommands:)` (see
diff hunks at lines 16-34 and 174-192 of that file). Neither `resumeCleanup` nor `cancelAndClean` —
the methods this finding is about — appear in the diff at all:

```
$ git diff HEAD -- Sources/FreeTalker/Workflows/Recovery/CaptureJournalService.swift
... (only the VoiceCommandFinalizationIntent struct and finish()'s new parameter change)
```

So the behavior this finding describes (recursively deleting a `.libraryCommitted` directory and
ledger row through `CaptureJournalService` without also deleting the recovery job, leaving a
stranded job pointing at a missing source after restart) is identical to `main` today.

**Suggested fix (follow-up PR):** Route file, job, and ledger cleanup for the retention-service path
through the same single finalizer `RecoveryCaptureService.cleanupLibraryCommittedSession` already
uses for the on-completion path, instead of `RecoveryRetentionService` calling
`CaptureJournalService.resumeCleanup` directly.

---

## Note on scope discipline

Per the round-7 review brief, only findings whose flawed behavior is introduced or made worse by
this PR's diff were fixed in this pass (with regression tests). F1/F2/F3 above were deliberately
left untouched because "fix root causes, minimal impact" here means not rewriting pre-existing
`RecoveryRetentionService`/`RecoveryCaptureService` segment-deletion behavior as a side effect of the
voice-command-layer PR. All three are real and worth a dedicated follow-up PR.
