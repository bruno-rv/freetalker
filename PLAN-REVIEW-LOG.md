# Plan Review Log: Library deletion + Redo Last hotkey
Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md updated (Library, Re-process, Redo Last terms). MAX_ROUNDS=5.

## Round 1 — Codex (thread 019f47bf-aaef-7ba1-9729-f0cf13e58876)
12 findings, VERDICT: REVISE. (First run of round 1 hung 49 min at 0% CPU with no thread.started — killed, retry succeeded.)
1. Audio artifacts (`last-dictation.wav`, failed-transcription wavs) contradict "audio never retained/unrecoverable".
2. No secure_delete/VACUUM/WAL truncate — deleted text lingers in SQLite pages/WAL.
3. `source_id` FK (`REFERENCES dictations(id)`) conflicts with intended dangling provenance if FKs ever enabled.
4. Deleting a source leaves its transcript alive in re-processed derived rows — confirmation must say so or cascade.
5. Delete/reprocess race: deleteAll during an in-flight reprocess resurrects deleted text as a new row.
6. `LibraryStore.dictations.first` is filtered by the Library search text — redo would redo the newest SEARCH RESULT.
7. `ORDER BY ts DESC` alone — timestamp ties make "newest" nondeterministic.
8. Raw HotKeySpec equality misses side-agnostic modifier collisions (left-ctrl+alt vs right-ctrl+alt).
9. Prefix conflicts: modifier-only PTT engages on flagsChanged before a superset redo chord's keyDown fires.
10. Modifier-only redo spec would never produce a keyDown — redo never fires.
11. `db == nil` no-op delete makes a confirmed destructive action silently "succeed".
12. Redo spec changes never re-plumb the running event tap (start passes only hotKeySpec today).

### Claude's response
All 12 accepted; cheap-variant fixes chosen for 1, 2, 3, 4:
1. ACCEPTED (modified): Delete All purges audio artifacts; per-row delete doesn't (no row↔file mapping) and its dialog doesn't promise audio removal. CONTEXT.md Library term reworded honestly.
2. ACCEPTED (scoped): `secure_delete=ON` always; VACUUM + `wal_checkpoint(TRUNCATE)` on Delete All only — per-row delete stays cheap.
3. ACCEPTED (documented, no rebuild): FKs stay off permanently, code comment records the decision. Table rebuild rejected as churn.
4. ACCEPTED (copy change): per-row confirmation states re-processed copies remain. Cascade rejected — silently destroying user-visible entries is worse.
5. ACCEPTED: reprocess re-checks source row exists before persisting; still inserts at cursor, skips the Library write.
6. ACCEPTED: new `Database.latestDictation()` (ORDER BY id DESC LIMIT 1), bypasses store filter.
7. ACCEPTED: `ts DESC, id DESC` everywhere; latest-by-id.
8. ACCEPTED: side-normalized modifier comparison.
9. ACCEPTED: prefix-shadow rejection both directions in both recorders.
10. ACCEPTED: modifier-only redo specs rejected in recorder (keyCode required).
11. ACCEPTED: store delete methods throw; UI alerts.
12. ACCEPTED: start/restart plumbing carries both specs; re-plumb on either change.
PLAN.md rewritten (steps 1–13).

## Round 2 — Codex
5 findings, VERDICT: REVISE.
1. Finding-5 follow-up: normal dictation pipeline (not just reprocess) can finish after Delete All and write a fresh row.
2. Redo matcher must still be fed keyUp/flagsChanged — HotKeyMatcher is stateful (isEngaged/key-swallow reset on release).
3. CONTEXT.md named only the latest debug copy; plan purges failed-transcription audio too.
4. Redo conflates DB-unavailable with empty Library ("Nothing to redo").
5. wal_checkpoint(TRUNCATE) reports busy via result columns, not exec error — must check.

### Claude's response
All 5 ACCEPTED:
1. Delete All disabled while isRecording || isProcessing (UI guard; per-row delete unaffected).
2. keyUp/flagsChanged fed to redo matcher for state reset; callback only on engage.
3. CONTEXT.md Library term now names both artifact classes.
4. Distinct HUD "Library unavailable" on thrown DB error.
5. Checkpoint via prepared statement, busy column asserted; SelfCheck covers it.
PLAN.md patched in place.

## Round 3 — Codex
2 findings, VERDICT: REVISE.
1. Delete All guard is UI-only — dialog opened while idle can be confirmed after a hotkey dictation starts (TOCTOU).
2. Per-row delete leaves prior page images in WAL until checkpoint — secure_delete alone isn't privacy-grade.

### Claude's response
Both ACCEPTED:
1. Guard re-checked inside the destructive confirmation action right before deleteAll(); aborts with alert if failed.
2. Verified wal_checkpoint(TRUNCATE) after per-row delete too (VACUUM remains Delete-All-only).
PLAN.md patched.

## Round 4 — Codex
1 finding, VERDICT: REVISE.
1. Key-decision bullet still said WAL truncate "Delete All only" — contradicted step 1's per-row checkpoint.

### Claude's response
ACCEPTED: bullet reworded — WAL truncate after every delete; VACUUM + audio purge Delete-All-only.

## Round 5 — Codex
No blocking findings. VERDICT: APPROVED.

## Resolution
Converged in 5 rounds (12 + 5 + 2 + 1 + 0 findings; all 20 accepted, none rejected). Plan locked; parallel build dispatched.

# Code Review Log (post-merge, main @ 573fe58)

## Code Round 1 — Codex (thread 019f4847-8468-7bb0-87fa-f592bab7903d, model pinned gpt-5.5)
(Notes: first attempt hung on stdin — fixed with </dev/null; second 400'd on new default model gpt-5.6-sol — pinned gpt-5.5; third accidentally reviewed a stale worktree due to persisted shell cwd — worktrees removed, rerun from root.)
8 findings, VERDICT: REVISE.
1. Delete All confirmation shows FILTERED count ("0 Entries" under active search) while wiping whole archive.
2. Database.readAll treats any non-ROW step as EOF — latestDictation() turns SQLITE_BUSY/ERROR into nil, collapsing empty-vs-unavailable.
3. dictationExists returns false on SQLite errors — reprocess silently skips persistence as if source deleted.
4. deleteAll: checkpoint throw after successful DELETE skips audio purge + refresh.
5. Audio purge removes EVERY child of failed-dictations and swallows failures.
6. Hotkey re-plumb is manual in SettingsView — direct AppSettings changes leave stale matchers.
7. Redo two-matcher SelfCheck mirrors the dispatch instead of exercising production path.
8. wal_checkpoint busy path never exercised by SelfCheck.
Plus 2 carried from the mistargeted round (real redo-code findings): 9. redoLast shows success HUD even when Insertion.insert returns false; 10. persisted redoHotKeySpec decoded without constraint validation vs PTT.

### Claude's response
All 10 ACCEPTED (3 with fail-open semantics: on unknown DB state reprocess persists rather than drops). Fix agent dispatched.

## Code Round 2 — Codex
4 findings, VERDICT: REVISE (all partial-success refinements).
1. deleteAllDictations bundles DELETE+VACUUM — VACUUM failure after autocommitted DELETE skips purge/refresh.
2. Per-row delete same shape: checkpoint throw after committed DELETE skips refresh, deleted row stays visible.
3. contentsOfDirectory try? swallows enumeration failure — unreadable failed-dictations dir reports clean purge.
4. Extension-only purge scoping would recursively remove a DIRECTORY named *.wav.

### Claude's response
All 4 ACCEPTED: split committed-row-deletion from VACUUM/checkpoint at the Database API; store always refreshes (and purges, for deleteAll) once rows are committed-deleted, then surfaces privacy-step errors; enumeration failures feed audioPurgeFailed; purge checks isRegularFileKey.

## Code Round 3 — Codex
Blocked: Codex usage limit exhausted (resets 2026-07-10 00:46). Rounds 1–2 findings (10 + 4) all fixed and mutation-verified; no unaddressed findings. Bruno authorized push without the confirmatory round ("Push now"); round 3 to run later as post-merge audit.
