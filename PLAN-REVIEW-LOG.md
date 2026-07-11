# Plan Review Log: Speech Model picker
Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md updated (Speech Model term). MAX_ROUNDS=5.

## Round 1 — Codex
15 findings, VERDICT: REVISE.
1. recommendedModels() is local fallback config — use recommendedRemoteModels() async w/ fallback + cache.
2. Global default may be unsupported on M1-class — resolve default per device.
3. "Migration" claim wrong — need explicit prefixless→catalog-id alias normalization.
4. Literal HF path assumption unsafe — derive from actual download-return/HubApi layout.
5. Non-empty dir ≠ downloaded — require expected .mlmodelc artifacts.
6. Delete could hit shared cache structure — delete only exact resolved variant dir.
7. loadedFlag never-resets invariant breaks; audit isLoaded callers.
8. Engine-object snapshot doesn't pin the MODEL — shared engine means queued transcribe could use new kit; capture kit locally in performTranscribe.
9. Clear-then-load loses working model on failed reload — load-then-atomic-swap.
10. First-launch Active model may be not-downloaded — needs explicit UI state.
11. MainActor manager + heavy FS work — split state (main) from IO (background).
12. Row state vs global statusText can diverge — single observable state source.
13. "If support lookup fails" branch impossible for sync local call — moot with remote lookup.
14. large-v2 exclusion undocumented.
15. SelfCheck misses path mapping, reload-failure preservation, in-flight kit retention.

### Claude's response
All 15 ACCEPTED. Plan rewritten: remote support w/ cached fallback (1,13); per-device default + preference order (2); alias normalization (3); variantDirectory(for:) derived from real layout, verified on-machine (4); artifact-based detection (5); exact-dir delete + last-component assertion (6); loadedFlag = "some kit loaded", caller audit (7); kit capture in performTranscribe (8); load-new-then-swap w/ visible selection revert (9); "Active — downloads on first use" row state, selectable-rule applies to changes only (10); SpeechModelStore state-on-main/IO-background (11,12); large-v2 rationale documented (14); selfcheck adds path mapping, fake-loader reload-failure, kit-identity retention checks (15).

## Round 2 — Codex
9 findings, VERDICT: REVISE.
1. Stale "Key decisions" bullets contradicted the revised design (reset-then-load; local-only support intersect).
2. AppSettings init can't use async support cache — startup ordering undefined.
3. Reload-failure revert races newer user selection (A→B fails after user picked C → bounces to A).
4. Reload under the transcription gate blocks dictation for a whole model download.
5. Kit "capture at entry" undefined when whisperKit == nil mid-reload.
6. "ALL attempts route through store" vs engine-owned preload = circular ownership risk.
7. Deleting a reload-target variant mid-load uncovered.
8. Last-component-matches-catalog-id assertion too strict for fuzzy-resolved paths.
9. recommendedRemoteModels from Settings rendering can hang/flicker — no timeout/offline contract.

### Claude's response
All 9 ACCEPTED:
1. Stale bullets deleted.
2. Sync alias-normalization in init; device-default applied later by store, only if user never explicitly chose (whisperModelChosen flag).
3. reload(to:) reverts only if setting still equals the failed requested variant.
4. Download/load outside the gate; tiny gated swap; separate reload lock.
5. kitForTranscription() helper: loaded kit returned as-is (reload never clears); nil → normal gated load of current setting.
6. Ownership boundary: engine does active-variant load/reload downloads + emits events; store owns scans/deletes/manual downloads; one downloader per operation.
7. Reload target busy/non-deletable start→finish (new busy phase).
8. Assertion validates against variantDirectory(for:) output, not raw catalog id.
9. Render immediately from local fallback; background remote refresh w/ ~5s timeout tightens labels; rendering never awaits network.

## Round 3 — Codex
7 findings, VERDICT: REVISE.
1. Reload-outside-gate makes whisperKit/loadedVariant concurrently accessed — needs one guarded state, all reads/writes through it.
2. Separate loadedFlag can diverge — derive isLoaded from guarded kit != nil.
3. "One download at a time across layers" asserted, not designed — needs shared coordinator.
4. Engine preload vs manual download contention behavior undefined.
5. whisperModelChosen via shared setter path can be set by programmatic reverts.
6. Active model becoming unsupported after remote refresh — policy undefined.
7. SelfCheck wording still had the rejected last-component assertion.

### Claude's response
All 7 ACCEPTED:
1. Lock-guarded state struct (or actor) for whisperKit+loadedVariant; no bare access.
2. loadedFlag deleted; isLoaded derived.
3. SpeechModelDownloadCoordinator actor = sole WhisperKit.download caller, one slot.
4. Reject-visibly: other Download buttons disabled with "waiting for current download"; no hidden queue.
5. setWhisperModelFromUser(_:) flags; applyAutomaticWhisperModel(_:)/reverts use non-flagging setter.
6. Active loaded model stays usable, flagged unsupported; auto-migrate only when not user-chosen.
7. SelfCheck reworded: resolver self-consistency + cache-root containment.

## Round 4 — Codex
5 findings, VERDICT: REVISE.
1. Contradiction: "delete loadedFlag" vs next bullet still describing loadedFlag semantics.
2. Settings step still wrote settings.whisperModel directly, bypassing setWhisperModelFromUser.
3. Superseded reload request invisible in row state ("selected pending reload" missing).
4. First-launch preload should emit .downloading through the store like manual downloads.
5. SelfCheck missing guarded-state transition coverage.

### Claude's response
All 5 ACCEPTED: loadedFlag bullet rewritten as isLoaded-caller audit; Settings routes solely through setWhisperModelFromUser (single persist+flag+reload point); "selected — pending reload" row state; preload emits .downloading identically; selfcheck adds guarded-state transitions (nil→loaded, swap identity, failure preserves, isLoaded==kit!=nil).

## Round 5 — Codex
VERDICT: APPROVED. 3 non-blocking implementation notes carried into the build brief:
1. Prefer the download-returned folder URL as truth; pure resolver only for scan/delete, validated against it.
2. Reload memory spike (two models resident) — keep failure path robust for memory/load errors, clear status hint.
3. UI/README wording: "not recommended for this Mac; current model remains active" — unsupported ≠ broken.

## Resolution
Converged in 5 rounds (15 + 9 + 7 + 5 + 0 findings; all 36 accepted, none rejected). Plan locked.
