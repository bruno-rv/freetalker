# Plan Review Log: Spoken Commands + Language Pin + Recording Panel
Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md updated (Spoken Command, Language Pin, Recording Panel). MAX_ROUNDS=5.

## Round 1 — Codex (thread 019f4d2c-e224-7961-9e52-60d10710ffa2)
14 findings, VERDICT: REVISE.
1. "Small shared spot" for forced language = mutable singleton risk across preview/final calls.
2. Vocabulary/baseURL still read mid-transcribe while language is snapshotted — inconsistent determinism.
3. Per-app language as a "picker column" doesn't fit appRules-driven row model (Add requires Template).
4. Row removal deletes only appRules — stale language overrides survive invisibly.
5. Invalid one-shot could block valid rule/pin unless candidates normalize independently.
6. One-shot cleanup unspecified for early returns/pipeline failures.
7. refined==transcript marks raw AND post-processing fallback — indistinguishable.
8. Raw rows recording the skipped Template's name violates Library semantics.
9. HUD 460pt cap/preview-drop not specified as a layout contract.
10. Parent onTapGesture + child Buttons double-fire/swallow risk.
11. Panel template cycle contradicts glossary "no per-dictation picker".
12. Prompt-only spoken commands unverifiable by marker substrings; needs behavioral verification.
13. Cloud STT forced-language field compat undocumented.
14. Riskiest behavior (panel event delivery/focus) untested by SelfCheck.

### Claude's response
All 14 ACCEPTED (12 fully, 2 scoped):
1. Protocol change: transcribe(samples:forcedLanguage:), preview passes nil, no shared state.
2. Accepted as documented asymmetry (code comment): vocab/baseURL keep pre-existing engine-read pattern; language snapshot-threaded because one-shot is dictation-scoped.
3+4. Unified per-app rule row (template-only/language-only/both); removal clears BOTH dicts; storage unchanged.
5. Per-candidate normalization with fall-through; selfcheck covers invalid-one-shot→valid-rule.
6. defer-based clearing on every terminal path incl. empty-samples return; reset at beginCapture.
7+8. One fix: raw rows record reserved template name "Raw Transcript" — distinguishes from fallback (real name) and honors Library semantics. No schema change.
9. Layout contract: maxWidth 460, template label truncates ~120pt, preview drops first, controls never drop.
10. Panel mode removes whole-capsule gesture; per-control callbacks only.
11. CONTEXT.md Active Template term updated: panel cycles the GLOBAL selection; no per-dictation template.
12. SCOPED: selfcheck = prompt markers + guard sentence (no LLM in selfcheck env); behavior via manual E2E checklist (new step 15).
13. Documented: OpenAI-compatible field, sent only when forced; rejection surfaces via existing status mapping.
14. SCOPED: manual smoke-test checklist added as step 15 (panel focus/double-fire/paste-target, language precedence, command E2E).

## Round 2 — Codex
5 findings, VERDICT: REVISE.
1. Protocol change collides with preview-only transcribe(samples:allowEarlyCancel:) — needs explicit overload.
2. CloudSTTError.badResponse leaks raw response body into localizedDescription/lastError.
3. "Raw Transcript" reserved name can collide with a user-created template of that name.
4. Stale template ID in unified row: display/resolution/cleanup semantics unspecified; language half must not be silently preserved or silently killed.
5. Panel double-click/near-simultaneous controls can fire after state already left recording.

### Claude's response
All 5 ACCEPTED:
1. Overload transcribe(samples:forcedLanguage:allowEarlyCancel:); witness passes false; preview passes (nil, true).
2. badResponse redacted to status + classified hint, same contract as CloudLLMError/ConnectionTest.
3. TemplateStore.upsert rejects "Raw Transcript" (case-insensitive, trimmed) with UI feedback.
4. Row shows "(deleted template)", language half keeps working (resolveLanguage independent by design), row removable as one unit.
5. Every panel callback routes through the state machine from current state; idle + panel events → .none in the pure table, selfcheck-covered.

## Round 3 — Codex
4 findings, VERDICT: REVISE.
1. pillClick from pttRecording LOCKS — Done/Raw need their own stop event.
2. Cloud STT `decoded.language ?? "en"` fallback records EN for forced-PT dictations.
3. upsert-only reservation misses pre-existing user template named "Raw Transcript" on disk.
4. Glossary Transcript term still said language is always auto-detected.

### Claude's response
All 4 ACCEPTED:
1. New `.panelFinish` event → stopAndTranscribe from pttRecording AND locked, .none from idle; Lock keeps pillClick; Cancel keeps esc-path.
2. forcedLanguage != nil ⇒ TranscriptionOutput.language = forced code.
3. Load-time rename of pre-existing collisions to "Raw Transcript (Template)", persisted.
4. CONTEXT.md Transcript term updated (auto-detected unless pinned/ruled/panel-forced).

## Round 4 — Codex
No material remaining findings. VERDICT: APPROVED.

## Resolution
Converged in 4 rounds (14 + 5 + 4 + 0 findings; all 23 accepted, none rejected). Plan locked; parallel build dispatched.

# Code Review Log (post-merge, main @ f9fa0b7)

## Code Round 1 — Codex (thread 019f4d56-a993-7b42-9471-45bbdf85eafc, gpt-5.5)
1 finding, VERDICT: REVISE: App Rules Add merged non-nil halves instead of replacing the row — stale template override survives a language-only re-add.

### Claude's response
ACCEPTED: pure AppSettings.applyingAppRule replaces the whole row (nil half removes that dict's entry); UI routes through it; selfcheck + mutation-tested. Commit 507a0e6.

## Code Round 2 — Codex
No new findings. VERDICT: APPROVED.

## Resolution
Code converged in 2 rounds (1 finding, accepted+fixed). (Ops note: round 2 first attempts failed on a bad thread-ID extraction of mine — resume with empty ID hangs; lesson saved to memory.)
