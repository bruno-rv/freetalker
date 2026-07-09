# Plan: Library deletion + Redo Last hotkey
_Locked via grill-with-docs — by Claude + FreeTalker contributor. Terms per CONTEXT.md. Revised after Codex round 1._

## Goal
Two independent features, built in parallel. (A) The Library gains deletion: any single Dictation can be removed, and the entire archive can be cleared, both behind explicit confirmation. (B) A new optional **Redo Last** hotkey re-inserts the newest Library entry's Refined Output at the current cursor: one keystroke recovers from wrong-app pastes, accidental dismissals, or paste-target-drift fallbacks. It is unbound by default and never records or re-processes.

Discovery note: the originally requested "Library window" already ships (`LibraryView.swift`: FTS search, transcript/refined view, per-field copy, Re-process with… menu saving a new sourced entry). Scope is therefore only the two gaps above.

## Approach

### Feature A — Library deletion (agent A)
1. `Database` (Storage/Database.swift):
   - On open, `PRAGMA secure_delete=ON` (deleted page content is zeroed — deletion is a privacy feature).
   - `func deleteDictation(id: Int64) throws` — `DELETE FROM dictations WHERE id = ?`, followed by the same verified `wal_checkpoint(TRUNCATE)` — with secure_delete on, per-row deletion is privacy-grade only if prior page images don't sit in the WAL. The existing `dictations_ad` AFTER DELETE trigger syncs `dictations_fts`; no FTS code needed.
   - `func deleteAllDictations() throws` — `DELETE FROM dictations`, then `VACUUM` and `PRAGMA wal_checkpoint(TRUNCATE)` so cleared text doesn't linger in free pages or the WAL. The checkpoint runs as a prepared statement and its result row's busy column is checked — SQLite reports checkpoint-busy via result columns, not an exec error.
   - `func latestDictation() throws -> Dictation?` — `ORDER BY id DESC LIMIT 1` (shared with Feature B; id is the monotonic tiebreaker, `ts` alone can tie).
   - `allDictations()`/`searchDictations()` ordering hardened to `ts DESC, id DESC`.
   - The `source_id INTEGER REFERENCES dictations(id)` column: SQLite FKs stay OFF (never `PRAGMA foreign_keys=ON` in this app — documented in code comment); dangling `source_id` after source deletion is intended provenance behavior, no table rebuild.
2. `LibraryStore` (Storage/LibraryStore.swift): `func delete(id: Int64) throws` and `func deleteAll() throws` — call the `Database` method then `refresh()`; when `db == nil` they THROW (a confirmed destructive action must never silently no-op). UI catches and shows the error.
3. Audio artifacts: `deleteAll()` also removes the transient debug recordings on disk (`last-dictation.wav` and failed-transcription audio files in Application Support) — clearing the archive must not leave audio behind. Per-row delete does not touch them (no row↔file mapping); the per-row confirmation text doesn't promise audio removal.
4. `LibraryView` (UI/LibraryView.swift):
   - Per-row delete: context-menu Delete on list rows + Delete button in `DictationDetailView` (swipe-to-delete only if it renders acceptably in the HSplitView List; otherwise skip). ONE `confirmationDialog` (destructive role); text notes that Re-processed copies of this Dictation, if any, are separate entries and remain.
   - "Delete All…" action, own `confirmationDialog` stating the count, irreversibility, and that saved debug audio is purged too. Delete All is DISABLED while `isRecording || isProcessing` (AppCoordinator flags) — an in-flight dictation finishing after the wipe would otherwise write a fresh row containing just-deleted-era text. The flags are RE-CHECKED inside the confirmation's destructive action immediately before `deleteAll()` (dialog can sit open while a global hotkey starts a dictation); if the guard fails at confirm time, the action aborts with an explanatory alert. Per-row delete needs no such guard (a new insert doesn't resurrect a deleted row).
   - Deleting the currently selected Dictation clears the detail-pane selection. Errors from the store surface as an alert.
5. Re-process race guard: `AppCoordinator.reprocess` re-checks the source row still exists immediately before `LibraryStore.record(...)`; if deleted mid-flight (e.g. Delete All while the LLM call ran), the result is still inserted at the cursor but NOT persisted.
6. SelfCheck (temp DB): insert 2 rows → delete 1 → FTS no longer finds it, still finds the survivor, count correct; `deleteAll` empties table and FTS and `latestDictation()` returns nil; deleting a source row leaves the derived row readable with dangling `source_id`; `latestDictation()` picks higher id on identical `ts`; secure_delete pragma reads back as ON. Mutation-test each assertion (invert → fail → restore).

### Feature B — Redo Last hotkey (agent B)
7. `AppSettings`: `redoHotKeySpec: HotKeySpec?` (`@Published`, JSON in UserDefaults, same pattern as `hotKeySpec`; optional — nil = unbound = dormant). Default nil.
8. `HotKeyManager`: the existing single CGEventTap feeds a second optional `HotKeyMatcher`. `start(...)` (and every restart site) takes BOTH specs; changing either setting in `AppCoordinator` re-plumbs the manager (today only `hotKeySpec` is passed at AppCoordinator.swift:110). New closure `onRedoKeyDown` fires once per chord press (autorepeat ignored). keyUp and flagsChanged events ARE still fed to the redo matcher — `HotKeyMatcher` is stateful (`isEngaged`/key-swallow reset on release, HotKeySpec.swift:151) — but release never invokes the callback. PTT matcher untouched. No new tap ⇒ no new TCC grant.
9. Redo spec constraints (recorder-level, pure functions for SelfCheck):
   - Modifier-only redo specs REJECTED — redo needs a terminating keyDown (`HotKeyCapture` currently allows modifier-only; the redo recorder requires `keyCode != nil`).
   - Collision check compares side-normalized modifier sets (left/right ctrl fold together — runtime matching is side-agnostic per HotKeySpec.swift:185), not raw struct equality.
   - Prefix conflict REJECTED both directions: a redo chord whose modifier set is a superset of a modifier-only PTT spec would engage PTT on flagsChanged before redo's keyDown ever arrives (e.g. PTT=⌃⌥, redo=⌃⌥D) — recorder refuses it with inline text, and re-recording PTT refuses specs that would newly shadow the bound redo chord.
10. `AppCoordinator`: `func redoLast()` — guards `!isRecording && !isProcessing`; fetches `Database.latestDictation()` (NOT `LibraryStore.dictations.first` — that array is filtered by the current Library search text); nil → HUD "Nothing to redo"; a THROWN DB error → HUD "Library unavailable" (distinct state, not conflated with empty); else `Insertion.insert(dictation.refined)` (no target — same permissive path `reprocess` uses) + brief HUD confirmation. Guard + choice extracted as a pure function.
11. Settings UI: "Redo-last key" recorder row under the PTT row, Clear button (back to unbound), inline collision/constraint messages, one-line caption.
12. SelfCheck: redo gating truth table (recording/processing/empty/unbound); spec-constraint table — modifier-only rejected, side-normalized equality rejected, prefix-shadowing rejected both directions, disjoint chord accepted; matcher pass: with both specs bound, redo chord fires exactly once per press and PTT chord still matches. Mutation-test each.

### Integration (after both agents land)
13. `make app` + `make selfcheck` green on the merged tree; update README (Library: delete + Delete All incl. audio purge note; Settings: redo key row).

## Key decisions & tradeoffs
- **Redo = re-insert only, never re-process** — re-processing lives in the Library window; hotkey stays instant and side-effect-free.
- **"Last" = newest Library row by id, straight from the DB** — survives restart, includes Re-process results, immune to the Library window's search filter and `ts` ties.
- **Unbound by default; modifier-only redo disallowed** — no default chord to steal; chord must end in a real key so keyDown semantics are unambiguous.
- **Collision = side-normalized equality + prefix shadowing, both directions** — raw equality would pass chords that collide at runtime.
- **Delete granularity: single row + Delete All, each confirmed** — no multi-select model.
- **Deleting a source keeps derived rows; confirmation says so** — `source_id` is provenance, not a dependency; cascade would silently destroy user-visible entries containing the same transcript, so the dialog is explicit instead.
- **Privacy-grade deletion: secure_delete always on; verified WAL truncate after every delete (per-row and Delete All); VACUUM + audio-artifact purge on Delete All only** — full clear leaves nothing behind, single delete leaves no page images in the WAL.
- **Store delete throws on unavailable DB** — destructive UI actions never silently succeed.
- **Second matcher on the existing tap** (not a matcher registry) — smallest diff consistent with the single-tap design.

## Risks / open questions
- Swipe-actions inside `HSplitView` List on macOS may render poorly — context-menu + detail-pane button are the guaranteed paths (agent A decides visually, no ask-back).
- Redo pastes into whatever is focused — including a password field; acceptable for a personal tool, mitigated by explicit opt-in binding.

## Out of scope
- Multi-select deletion; undo for deletes; per-row audio purge.
- Redo picker/menu variants; re-process-from-hotkey.
- Enabling SQLite foreign-key enforcement; schema/table rebuilds.
- Spoken-command templates (candidate feature #2 — not requested now).
- Any change to recording, STT, post-processing routing, or Template behavior.
