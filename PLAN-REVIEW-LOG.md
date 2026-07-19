# Plan Review Log: Voice command layer + self-learning vocabulary
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

## Round 1 — Codex
Material problems remain:

1. **Toggle semantics are impossible as written.** Built-in templates already embed spoken-command rules for paragraphs, quotes, lists, caps, and “scratch that,” so PR A would duplicate instructions when enabled while “off” still executes commands ([Template.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/Template.swift:8)).  
   Fix — Extract the legacy rules into the new policy with a built-in-template migration, or explicitly scope the toggle to keyword commands only.

2. **The claimed single request-construction choke point does not exist.** Live dictation, recovery, translation, and Scratchpad transformations construct requests independently ([AppCoordinator.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/AppCoordinator.swift:3215), [TranslationService.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Workflows/Translation/TranslationService.swift:49), [ScratchpadTransformationService.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift:118)).  
   Fix — Add an explicit `VoiceCommandPolicy` to `PostProcessingRequest` and define it separately at every constructor, including recovery.

3. **The proposed injection layer conflicts with the prompt trust boundary.** Product rules currently belong in the trusted system prompt while templates are explicitly untrusted user content ([PostProcessor.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Engines/PostProcessor.swift:75)); appending the block to a template weakens enforcement, while interpolating editable keywords into system text permits prompt injection.  
   Fix — Keep fixed command rules in system instructions, encode validated/bounded keywords as data, and forbid spoken commands from overriding fixed output rules.

4. **The command grammar is internally contradictory.** “Multiple commands allowed” and “keyword-to-end-of-utterance scope” provide no boundary between successive commands or between an instruction and later dictated content.  
   Fix — Specify an unambiguous scope rule with examples for command termination, successive commands, quoted keywords, and post-command content.

5. **Settings persistence and temporal semantics are missing.** `AppSettings`, backup decoding, restore, and export enumerate settings explicitly ([AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:1063), [BackupBundle.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/BackupBundle.swift:91)), while processing already snapshots relevant settings at stop time ([AppCoordinator.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/AppCoordinator.swift:1930)).  
   Fix — Plan validation, bounds, UserDefaults loading, backup/restore, stop-time snapshotting, and recovery semantics for both new settings.

6. **The mining signal is not valid for arbitrary library rows.** Templates perform broad rewrites, translation rows intentionally change language, and “out-of-vocabulary” is undefined for language-agnostic BPE tokenization ([Template.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/Template.swift:17), [Dictation.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/Dictation.swift:19)).  
   Fix — Mine only anchored local substitutions from same-language, non-raw, non-command transformations; exclude translations and remove or precisely define “OOV.”

7. **Backfill is not idempotent.** Repeated scans, incremental processing racing a scan, or crash-and-retry will increment aggregate JSON counts repeatedly because no processed-dictation identity is stored.  
   Fix — Store per-dictation candidate evidence with a unique `(dictationID, normalizedTerm)` key and derive recurrence from distinct dictations.

8. **A sidecar JSON store creates unnecessary consistency and deletion problems.** The existing SQLite library already provides stable row IDs, transactions, secure deletion, and deletion operations ([Database.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/Database.swift:25), [LibraryStore.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/LibraryStore.swift:165)); aggregate JSON cannot correctly retract evidence when history is deleted.  
   Fix — Use versioned SQLite candidate/evidence tables with foreign keys and transactional approve/dismiss operations instead of JSON.

9. **Approval can silently do nothing.** `vocabulary` is derived from `vocabularyText`, and existing bounds retain the first 100 terms/600 bytes ([AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:528)); appending an approved term near the cap may leave it persisted but inactive.  
   Fix — Merge into normalized `vocabularyText` only after proving the term fits, otherwise require an explicit eviction choice and record approved state transactionally.

10. **The plan claims a token guarantee using a byte budget.** WhisperKit receives actual tokenizer output, whereas Settings limits UTF-8 bytes rather than tokens ([WhisperKitEngine.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Engines/WhisperKitEngine.swift:554), [AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:570)).  
    Fix — Enforce the Whisper prompt-token limit using its tokenizer, with deterministic ordering shared by preview, final transcription, and approval UI.

11. **“Scan library” can freeze Settings and exhaust memory.** `LibraryStore` is main-actor isolated and `allDictations()` loads every full transcript/refined pair at once ([LibraryStore.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/LibraryStore.swift:3), [Database.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/Database.swift:263)).  
    Fix — Add a paged projection scan off the main actor with cancellation, progress, and bounded batches.

12. **Verification and observability are inadequate for a default-on stochastic feature.** Prompt snapshots prove assembly, not command accuracy, false-positive rates, provider compatibility, or safe mining failure behavior.  
    Fix — Add an EN/PT behavioral evaluation matrix across Apple FM and supported cloud shapes, plus non-content telemetry/logging for mining failures, scan progress, and command fallbacks before enabling by default.

VERDICT: REVISE
### Claude's response
Accepted 1-11: system-prompt trust boundary with keywords-as-data; explicit VoiceCommandPolicy per request constructor (translation/scratchpad-transform hard-disabled); sentence-scope grammar with examples; built-in template migration to de-duplicate legacy spoken-command rules; full settings lifecycle incl. stop-time snapshot and backup/restore; mining restricted to anchored local substitutions on same-language non-translation rows, OOV dropped; SQLite evidence tables with (dictation_id, term) PK, cascade deletes, idempotent backfill; approval gated on surviving vocabulary normalization caps with explicit eviction; token-based Whisper budget via tokenizer with deterministic ordering; paged off-main-actor scan with cancel/progress; non-content observability logging.
Modified 12: full EN/PT×provider behavioral eval matrix rejected as over-scoped; replaced with default-OFF first ship + fallback logging + post-validation flip. Rationale: eval matrix gates the branch on infrastructure the product doesn't have; default-off removes the stochastic-default risk the finding actually targets.

## Round 2 — Codex
Most prior findings are addressed: request-path policy, trust boundary, grammar, mining restrictions, SQLite evidence, idempotence, deletion consistency, and paged scanning are now credible.

Default-OFF is an acceptable replacement for the full eval matrix for the first opt-in release. It is not sufficient evidence for the later default-ON flip, because fallback logs detect processor errors or empty responses—not semantic command failures or false positives ([AppCoordinator.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/AppCoordinator.swift:3140)).

Material issues remain:

1. **The command snapshot is not durably specified.** Recovery attempts currently persist only language, speech model, and template, while library rows have no command-policy flag ([TranscriptionJob.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/TranscriptionJob.swift:75), [Dictation.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/Dictation.swift:15)); therefore recovery cannot reproduce the original keywords and PR B cannot identify command-processed rows during backfill.  
   Fix — Add migrated persistent fields for enabled state plus keyword snapshot in recovery configuration, and a `voice_commands_active` library column defaulting false for legacy rows.

2. **“Transactional approval” is impossible across SQLite and UserDefaults.** The plan updates `vocab_terms` in SQLite and `vocabularyText` in UserDefaults atomically, but those stores share no transaction; it also says approved terms are merged into `vocabularyText` while later distinguishing user-entered from approved terms by approval date ([AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:539)).  
   Fix — Choose one source of truth—prefer keeping approved terms in SQLite and deriving one centralized effective vocabulary—or specify an idempotent two-phase write with startup reconciliation and provenance rules.

3. **The post-validation flip has no valid evidence gate.** Logging “policy enabled” and ordinary post-processing fallback cannot determine whether a command succeeded, was ignored, or accidentally consumed legitimate speech.  
   Fix — Keep default-ON explicitly out of these PRs and require a separately reviewed flip with defined evidence, such as opt-in feedback plus a small representative EN/PT/provider acceptance suite and zero unresolved semantic regressions.

4. **Edited built-ins bypass the OFF policy.** The migration only safely upgrades recognized built-in bodies; an edited built-in retaining the legacy command suffix will continue interpreting commands with the toggle off, contradicting the default-OFF mitigation and toggle contract ([Template.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/Template.swift:8), [TemplateStore.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/TemplateStore.swift:79)).  
   Fix — Strip the exact known legacy command suffix from every built-in-ID prompt while preserving all other edits, or explicitly detect and warn before leaving it active.

5. **The byte-identical disabled-prompt test is still impossible for migrated built-ins.** Removing their embedded command section necessarily changes their user-role prompt even when the new policy is disabled.  
   Fix — Assert byte identity only for system instructions and unchanged/custom templates, and separately assert the exact intentional built-in-template delta.

6. **Approval can still become silently inactive when the tokenizer is unloaded.** The plan permits estimated approval but postpones exact token enforcement until transcription, recreating the failure where an approved term is later truncated ([WhisperKitEngine.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Engines/WhisperKitEngine.swift:555)).  
   Fix — Use a mathematically conservative bound that guarantees fit, load the tokenizer before approval, or mark approval pending until exact validation succeeds.

7. **SQLite ownership and growth bounds remain unspecified.** The scan, incremental hook, and UI decisions can write concurrently, while the existing library façade is main-actor isolated; mined tokens also lack a maximum byte length, per-dictation candidate cap, and index optimized for recurrence queries ([LibraryStore.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/LibraryStore.swift:3)).  
   Fix — Route all candidate writes through a dedicated store actor/serialized connection, cap terms and evidence per dictation, and index `vocab_evidence(normalized_term, dictation_id)`.

VERDICT: REVISE
### Claude's response
Accepted all 7: (1) durable command snapshot — recovery config fields + voice_commands_active library column, migrations; (2) approved terms live in SQLite only, effective vocabulary derived at one code point (no cross-store transaction); (3) default-ON flip removed from scope, future change with its own evidence gate; (4) migration strips exact legacy suffix from edited built-ins, unrecognized variants left + one-time Settings warning; (5) byte-identity test scoped to system instructions + custom templates, built-in delta asserted exactly; (6) approval fit-gate uses conservative bytes<=token-budget bound (BPE tokens >=1 byte) or exact tokenizer when loaded — nothing deferred to transcription; (7) dedicated store actor for all vocab writes, 64-byte term cap, <=10 candidates/dictation, recurrence index.

## Round 3 — Codex
Round-2 findings 2–5 are addressed. Findings 1, 6, and 7 are only partially resolved, and several new persistence issues appear.

1. **The original command snapshot is still stored too late.** `AttemptConfiguration` is created when retry begins, but the provisional recovery job is created earlier without that configuration; after a crash, there is no original snapshot to copy into the attempt ([TranscriptionJobStore.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/TranscriptionJobStore.swift:89), [RecoveryRetryPipeline.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Workflows/Recovery/RecoveryRetryPipeline.swift:86)).  
   Fix — Persist the command snapshot on the provisional recovery job or capture session during `registerJournalCapture`, then copy it into each retry attempt; use nullable fields for legacy “snapshot absent” semantics.

2. **Approved vocabulary loses its correct surface spelling.** `vocab_terms` stores only `normalized_term`, status, and date; after evidence is cascade-deleted, casing/accents such as `OpenAI` or `João` exist nowhere, so the effective vocabulary can only reconstruct the normalized key.  
   Fix — Persist a validated canonical `surface_term` on the approved decision row and define a deterministic frequency/recency tie-breaker when choosing it.

3. **The effective-vocabulary consumer list is incomplete.** Existing vocabulary feeds both cloud and Apple post-processing, but the plan names only WhisperKit, Cloud STT, and Settings; `CloudLLMSettingsSnapshot` and `AppleFMProcessor` currently consume `AppSettings.vocabulary` directly ([AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:983), [AppleFMProcessor.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Engines/AppleFMProcessor.swift:24)).  
   Fix — Route WhisperKit, Cloud STT, cloud LLM snapshots, Apple FM, and Settings through the same effective-vocabulary derivation.

4. **Approved terms silently fall out of backups.** The backup bundle is explicitly config-only and currently exports `vocabularyText`; moving approved terms exclusively into `library.db` means user-approved vocabulary will not survive a backup/restore to another installation ([BackupBundle.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/BackupBundle.swift:544)).  
   Fix — Add approved surface terms and decision dates to a versioned backup format, or explicitly declare and surface that approved suggestions are excluded from backups.

5. **Candidate deletion semantics remain incomplete.** Cascading deletes remove `vocab_evidence`, but `vocab_terms(status = suggested)` has no foreign key and retains normalized transcript-derived data after every supporting dictation is deleted.  
   Fix — Derive suggested state solely from evidence, reserve `vocab_terms` for explicit approved/dismissed decisions, and define whether Delete All preserves or clears those decisions.

6. **The dedicated actor does not eliminate cross-connection races.** Library deletion still occurs through `LibraryStore` on another SQLite connection, so a scan can read a row, lose it to deletion, and then fail its evidence insert on the foreign-key constraint ([LibraryStore.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Storage/LibraryStore.swift:165)).  
   Fix — Coordinate deletion with the vocabulary actor or treat missing-row/foreign-key conflicts as benign skipped evidence inside an idempotent transaction.

7. **The conservative fit proof needs the exact serialized prompt and shared validation.** The bound must include the leading space and every `", "` separator, while approved terms currently use a 64-byte cap that conflicts with the existing 50-byte NFC/control-character validator ([AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:605), [WhisperKitEngine.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Engines/WhisperKitEngine.swift:554)).  
   Fix — Apply one shared term validator to manual and approved terms and calculate the fallback bound over the exact serialized Whisper prompt bytes.

VERDICT: REVISE
### Claude's response
Accepted all 7: (1) snapshot persisted at provisional-job creation via registerJournalCapture, nullable legacy semantics, copied into each AttemptConfiguration; (2) canonical surface_term stored on the decision row, frequency-then-recency tie-break at approval time; (3) effective-vocabulary derivation routed to all five consumers incl. CloudLLMSettingsSnapshot and AppleFMProcessor; (4) approved decisions added to versioned BackupBundle section, evidence excluded and documented; (5) vocab_terms renamed vocab_decisions, holds only approved/dismissed, suggested derived from evidence, Delete All clears evidence preserves decisions; (6) scan-vs-delete FK conflicts treated as benign skips in idempotent transaction; (7) single shared 50-byte NFC validator for manual+approved terms, fit bound over exact serialized prompt bytes.

## Round 4 — Codex
All seven round-3 findings are addressed in the revised text. New material problems remain:

1. **A crash window still loses the command snapshot.** The plan persists it when `registerJournalCapture` creates the provisional job, but audio is durably staged before that call; recovery reconciliation can recreate a missing job after a crash, while the stop-time snapshot exists only in memory and is absent from `CaptureSession` ([RecoveryCaptureService.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Workflows/Recovery/RecoveryCaptureService.swift:168), [CaptureSession.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/CaptureSession.swift:13)).  
   Fix — Persist the stop-time command snapshot on `capture_sessions` before or atomically with the staged transition, then copy it into the provisional job and attempts.

2. **Legacy rows are incorrectly classified as command-free.** `voice_commands_active DEFAULT false` marks historical rows false even though built-in templates already executed spoken-command conventions; backfill can therefore mine command-generated casing changes such as “all caps” ([Template.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Models/Template.swift:8)).  
   Fix — Use nullable `voice_commands_active` with `NULL = legacy/unknown` and exclude unknown rows from mining unless a conservative legacy eligibility rule proves them safe.

3. **Approval-time fit is not stable.** Manual vocabulary always has priority and remains freely editable; a later `vocabularyText` edit or backup restore can consume the budget and silently displace previously approved SQLite terms despite the plan’s guarantee ([AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:539)).  
   Fix — Revalidate the combined effective vocabulary after every manual edit, model change, startup, and restore, exposing displaced approved terms and requiring an explicit eviction decision before claiming they remain active.

4. **The decisions schema lacks uniqueness and integrity constraints.** Unlike evidence, `vocab_decisions` declares no primary key, so conflicting approved/dismissed rows for one normalized term remain possible; `status` and approved `surface_term` nullability are also unconstrained.  
   Fix — Define `PRIMARY KEY(normalized_term)`, `CHECK(status IN ('approved','dismissed'))`, conditional surface requirements, and deterministic upsert behavior.

5. **Backup restore conflict semantics are undefined.** Restoring decisions onto an installation with existing approved/dismissed decisions could overwrite, resurrect, or duplicate user intent, and the current restore pipeline reports staged partial application rather than rolling every store back ([BackupBundle.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/BackupBundle.swift:571)).  
   Fix — Validate and bound the entire decisions section before writes, define replace-versus-merge and timestamp conflict rules, and expose vocabulary restoration as a named stage with partial-failure reporting.

6. **The central effective-vocabulary path conflicts with synchronous stop-time snapshotting.** Approved terms live behind a store actor, but `cloudLLMSnapshot` and `makeStopRequest` are synchronous; querying SQLite during stop would either block the main actor or move the snapshot past an `await`, weakening its temporal guarantee ([AppSettings.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/Settings/AppSettings.swift:1043), [AppCoordinator.swift](/Users/bruno/Dev/freetalker/Sources/FreeTalker/AppCoordinator.swift:1930)).  
   Fix — Maintain an immutable, eagerly loaded approved-term cache published by the store actor and snapshot that cache synchronously with `vocabularyText` at stop.

VERDICT: REVISE
### Claude's response
Accepted all 6: (1) snapshot persisted on capture_sessions before/atomic with staged audio transition, inherited by reconciliation-recreated jobs; (2) voice_commands_active nullable, NULL=legacy/unknown excluded from mining; (3) continuous fit revalidation (manual edit, model change, startup, restore) with visible displaced state + explicit eviction; (4) vocab_decisions PK(normalized_term), status CHECK, approved-requires-surface CHECK, newer-decided_at upsert; (5) decisions restore as named validated stage, merge-by-newer-decided_at, partial-failure reporting; (6) immutable eagerly-loaded approved-terms cache published by store actor, snapshotted synchronously at stop.

## Round 5 — Codex
All six round-4 findings are addressed:

- Command snapshots persist with capture sessions before/with staging.
- Legacy command state is nullable and excluded from mining.
- Vocabulary fit is continuously revalidated with visible displacement.
- Decision schema now has uniqueness and integrity constraints.
- Backup restore has validation, conflict rules, and staged failure reporting.
- Synchronous stop-time paths use an eagerly loaded immutable cache.

No new material security, durability, concurrency, schema, or observability blockers remain. The plan is sound enough to implement.

VERDICT: APPROVED
Converged: VERDICT APPROVED at round 5 of 5.
