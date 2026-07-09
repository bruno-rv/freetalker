# Plan Review Log: Ollama preset + Disfluency/Self-correction cleanup
Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md updated (Built-in Template, Disfluency, Self-correction). MAX_ROUNDS=5.

## Round 1 — Codex
VERDICT: REVISE. Findings:
1. Ollama cloud URL unverified — docs show native `/api/chat`; `/v1` examples are localhost.
2. "Empty base URL → Ollama default" never triggers: `cloudLLMBaseURL` defaults to Anthropic URL (AppSettings.swift:238).
3. Shared `cloudLLMKey` Keychain account sends one provider's secret to another's endpoint on provider switch.
4. Model default `claude-sonnet-4-5` silently wrong for Ollama.
5. `CloudLLMProcessor.process` reads settings via separate `await`s — mixed snapshot possible mid-request.
6. SelfCheck migration tests would touch real `templates.json` (TemplateStore singleton, private init).
7. "Save only if changed" conflicts with unconditional `save()` in store init (TemplateStore.swift:26).
8. UI can delete built-ins; migration only updates existing IDs — deleted built-ins never upgraded.
9. Exact new prompt strings deferred to build — unreviewable; "repeated words" removal may destroy meaning.
10. Cloud failure silently falls back to raw Transcript — misconfiguration looks like weak cleanup.

### Claude's response
- (1) Resolved empirically: unauthenticated POST probes — `https://ollama.com/v1/chat/completions` → 401, `/api/chat` → 401. Both exist; 401 not 404 ⇒ OpenAI-compatible cloud endpoint is real. Plan cites probe + keeps native `/api/chat` as E2E contingency.
- (2,4) Accepted: provider-aware defaults — on provider switch, base URL/model that are empty or equal another provider's known default swap to the new provider's default.
- (3) Accepted (security): provider-scoped Keychain accounts + legacy key migration.
- (5) Accepted: single MainActor settings snapshot.
- (6,7) Accepted: pure static migration function over `[Template]`; store saves on init only when seeded or migrated.
- (8) REJECTED: deleted built-in = deliberate user edit; re-seeding is hostile. Migration upgrades existing unedited built-ins only. Documented in plan.
- (9) Accepted: exact four prompts now in PLAN.md; wording targets *accidental* disfluencies, preserves intentional repetition/quotes/names.
- (10) Accepted: HUD notice + redacted log when post-processing falls back to raw Transcript.

## Round 2 — Codex
VERDICT: REVISE. Prior findings 2-7, 9, 10 addressed; rejection of 8 accepted as defensible; 1 accepted given E2E + contingency. New findings:
1. Switching Ollama → generic openAICompatible leaves ollama.com URL/model → generic key sent to Ollama.
2. Default normalization only in `didSet`; init assignments don't run `didSet` — persisted mismatches survive until manual toggle.
3. Legacy Keychain migration (copy-then-delete) unchecked; SelfCheck excludes Keychain IO — untested secret handling.
4. `reprocess` (AppCoordinator.swift:496) has same silent fallback as `processDictation` — fallback visibility incomplete.
5. `CloudLLMError.badResponse(Int, String)` exposes response body via LocalizedError — conflicts with redacted-logging goal.
6. Trim-whitespace compare silently overwrites whitespace-only user edits — contradicts "any edit makes it not match".

### Claude's response — all 6 accepted
- (1) Switching to a provider with no known default clears URL/model if they equal any known provider default; cloud call requires non-empty base URL (error → existing fallback).
- (2) `resolveProviderDefaults` also applied once in `AppSettings.init` after load (idempotent pure helper).
- (3) Migration idempotent + checked: skip if target account already set; delete legacy only after verified write to provider account. Logic extracted over an injectable key-store interface; SelfCheck tests it with an in-memory fake (no real Keychain IO).
- (4) Single fallback reporter used by both `processDictation` and `reprocess`.
- (5) `badResponse` no longer carries body into `LocalizedError` — status + provider label only; body never logged.
- (6) Invariant re-worded: "semantic edits are preserved; boundary-whitespace-only edits may upgrade" — trim compare kept deliberately.

## Round 3 — Codex
VERDICT: REVISE. Round-2 resolutions accepted. New findings:
1. Empty-model requests not guarded — only base URL validated; all three providers require a model.
2. Fallback reporter covers thrown failures only; empty/whitespace processor output also falls back silently.
3. "Empty"/"verbatim-equals" matching on user-typed fields — whitespace variants bypass defaulting/validation.

### Claude's response — all 3 accepted
- (1) `CloudLLMProcessor` validates trimmed base URL AND trimmed model non-empty before any request; typed error → shared fallback reporter.
- (2) Shared reporter invoked on both throw and empty-output fallback, in `processDictation` and `reprocess`.
- (3) All default-matching and validation on trimmed values; request uses the trimmed snapshot.

## Round 4 — Codex
VERDICT: APPROVED. All round-3 findings verified resolved. Remaining risks acknowledged as bounded: Ollama /v1 compat E2E-gated with native /api/chat contingency; deleted built-ins stay deleted by design; whitespace-only edits may upgrade by design.

## Resolution
Converged in 4 rounds (3× REVISE → APPROVED). 19 findings raised, 18 accepted, 1 rejected with logged rationale (re-seeding deleted built-ins). Awaiting user sign-off before implementation.

## Round 5 — Codex (Amendment A)
VERDICT: REVISE. Findings:
1. Stale approved-plan text contradicts amendment (step 7 "useCloud untouched", step 11 "enable Use cloud model", key decision "built-ins stay useCloud:false").
2. Silent behavior migration: existing complete config → all templates cloud without consent (privacy).
3. Expired/revoked key globally degrades refinement to raw with no recovery hint; A4 forbids FM retry.
4. Selection/execution race: coordinator checks key, processor re-reads Keychain later — can select cloud then fail raw.
5. SelfCheck misses legacy useCloud:false + complete-config routing case.

### Claude's response
- (1) Accepted: stale lines amended (marked "superseded by Amendment A").
- (2) REJECTED: implicit-on-config is the user's explicitly requested semantics (single-user personal app; the toggle caused 3 failed E2E rounds). A3 caption documents the rule. Consent ceremony would reintroduce the friction the change removes.
- (3) Partially accepted: FM retry stays out (user explicitly chose raw fallback when asked). Accepted: fallback HUD text gains recovery hint ("check API key/model in Settings; clear key for on-device").
- (4) Accepted: one snapshot (provider, base URL, model, key, vocabulary) captured at selection time and passed into CloudLLMProcessor — routing and request always agree.
- (5) Accepted: SelfCheck adds legacy useCloud:false decode + isCloudLLMConfigured routing truth table.

## Round 6 — Codex (Amendment A rev + Amendment B)
VERDICT: REVISE. A: step 4 still says processor reads settings itself (conflicts A1). B: (1) Esc not in event tap — would leak to frontmost app; (2) HUD ignoresMouseEvents=true today; clickable pill needs cannot-become-key panel + pre-click target snapshot; (3) cap timer can double-stop — needs recording generation + cancellation on terminal transitions; (4) pill-lock during PTT must ignore the subsequent physical key-up; (5) cancel side effects unspecified (capture, preview, timer, HUD, samples, no Library); (6) handsFreeMaxMinutes unbounded.

### Claude's response — all accepted
- A: step 4 amended to defer to A1 (single snapshot passed in).
- B1: tap detects keyCode 53 while recording only; swallowed then, passes through otherwise; selfcheck covers decision.
- B2: pill = NSPanel subclass overriding canBecomeKey/Main → false, mouse events enabled deliberately; insertion target snapshotted BEFORE handling click-stop.
- B3: recording generation ID; every terminal transition invalidates the cap timer; stale capReached(gen) for old gen = no-op, selfcheck-tested.
- B4: pttRecording + pillClick → locked(ignoreNextKeyUp); locked + keyUp → no-op. In transition table.
- B5: single cancelRecording terminal action: stop capture, cancel live preview, invalidate cap timer, clear HUD, discard samples, no pipeline/Library work. Selfcheck asserts via injected hooks.
- B6: handsFreeMaxMinutes clamped 1–60 on read and persist; clamp selfcheck-tested.

## Round 7 — Codex
VERDICT: REVISE. A coherent. B: (1) live-preview ticks replace whole pill text → would erase lock/elapsed state; (2) handsFreeMaxMinutes live-read vs snapshot at lock unspecified.

### Claude's response — both accepted
- (1) HUD rendering becomes mode-aware: locked layout = lock glyph + elapsed/cap, preview text embedded inside that layout; preview updates can never replace lock state.
- (2) Clamped cap snapshotted on entering locked, tied to the recording generation; Settings changes mid-recording don't affect the live recording.

## Round 8 — Codex
VERDICT: APPROVED. Amendments A and B clear; no new blocking issues.

## Resolution (amendments)
A + B converged in 4 rounds (5–8). 13 findings; 11 accepted, 2 rejected with logged rationale (consent ceremony, FM retry — both contradicted explicit user decisions). Building.
