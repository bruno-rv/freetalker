# Plan Review Log: FreeTalker
Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md/ADR-0001 created. MAX_ROUNDS=5.

## Act 2 — skipped
Codex round 1 failed on usage limit (reset 10:22 PM); OpenRouter judge unavailable (no API key by choice). User signed off on PLAN.md directly on 2026-07-07 and ordered implementation. Cloud BYOK stays a settings-only affordance; all default processing local (WhisperKit + Apple Foundation Models).

# Implementation Review (Codex, post-build) — thread 019f3e9f-0cb2-7c62-80fa-699357de6ddf

## Round 1 — Codex
14 findings, VERDICT: REVISE. Full text:

> Findings:
> 
> 1. `Sources/FreeTalker/AppCoordinator.swift:86`: Transcription errors discard the only captured audio and return with no Library row, no retry artifact, and no pasteboard fallback; a Whisper download/decoder/cloud error loses the dictated words. Fix: keep a temporary audio retry item until transcription succeeds or the user explicitly discards it.
> 
> 2. `Sources/FreeTalker/AppCoordinator.swift:94`: Empty transcription silently returns and hides the HUD, also losing the captured utterance with no error path. Fix: treat empty transcript as a failed dictation with retry/manual recovery instead of returning.
> 
> 3. `Sources/FreeTalker/AppCoordinator.swift:102`: Post-processors can return `""` without throwing, and the app will paste/record empty Refined Output instead of falling back to the Transcript. Fix: trim and validate `refined`, falling back to `transcription.text` when empty.
> 
> 4. `Sources/FreeTalker/Core/Insertion.swift:26`: `postCommandV()` reports success merely because events were constructed; it never checks AX focused element, so rejected paste still restores the old clipboard and strands the user. Fix: check the frontmost app’s AX focused element/editability before restore, and leave text on pasteboard when paste cannot be accepted.
> 
> 5. `Sources/FreeTalker/Core/Insertion.swift:29`: Fixed 0.3s pasteboard restore races both slow paste consumers and user clipboard changes; the dictated text can be replaced before the target app reads it. Fix: restore only if pasteboard `changeCount` is unchanged and after a safer paste confirmation/delay strategy.
> 
> 6. `Sources/FreeTalker/Core/AudioCapture.swift:20`: If `engine.start()` throws after `installTap`, the tap is left installed while `isCapturing` stays false, so the next start can crash/fail installing another tap. Fix: remove the tap in a `catch`/cleanup path when start fails.
> 
> 7. `Sources/FreeTalker/Core/AudioCapture.swift:59`: The AVAudioEngine tap thread appends to `samples` while `stop()` reads/returns it on the main actor; Swift Array mutation across threads is undefined and can corrupt or drop audio. Fix: serialize audio-buffer writes with a lock/queue or copy buffers off the render callback before aggregation.
> 
> 8. `Sources/FreeTalker/App.swift:15`: Initial event-tap creation failure is ignored; after the user grants Accessibility/Input Monitoring, the listener is not retried unless they relaunch or change hotkey. Fix: surface failed listener state and restart automatically when permission becomes trusted.
> 
> 9. `Sources/FreeTalker/UI/SettingsView.swift:30`: Settings only tracks Accessibility and gives no Microphone/Input Monitoring status/buttons despite PLAN.md requiring all three; denied mic/input permissions become dead-end setup. Fix: add live microphone/input-monitoring status and direct System Settings actions.
> 
> 10. `Sources/FreeTalker/Storage/LibraryStore.swift:16`: Database open/write failures are swallowed with `try?`, and `AppCoordinator` ignores `record` failure, so “All Dictations land in Library” is false under disk/permission/corruption errors. Fix: make persistence failures explicit and keep the transcript on pasteboard/export fallback until recorded.
> 
> 11. `Sources/FreeTalker/Engines/CloudSTTEngine.swift:49`: Cloud STT decodes `language` but does not request a response format that returns it; OpenAI-compatible default responses commonly contain only `text`, so every cloud dictation falls back to `"en"`. Fix: request verbose JSON/language metadata or run language detection before recording.
> 
> 12. `Sources/FreeTalker/AppCoordinator.swift:96`: The Active Template and engine name are read after async transcription; changing settings during a long model download/transcription can process/record the dictation under a different template or engine than the one active at key release. Fix: snapshot engine and template at key-up and pass them through the pipeline.
> 
> 13. `Sources/FreeTalker/Core/Keychain.swift:16`: `set` deletes the existing key before adding the new one and ignores `SecItemAdd` status, so a transient Keychain failure can erase a valid BYOK secret silently. Fix: use `SecItemUpdate`/checked add semantics and return/throw OSStatus.
> 
> 14. `Tests/FreeTalkerTests/FreeTalkerTests.swift:5`: The PLAN requires a runnable pipeline unit test with canned WAV -> non-empty Transcript, but tests/selfcheck only cover templates and FTS. Fix: add a canned-audio pipeline check or injectable fake engine test that exercises capture-to-transcript contract.
> 
> VERDICT: REVISE
### Claude's response (round 1)
Accepted all 14, minimal-diff fixes applied: failed/empty transcription now saves audio WAV to failed-dictations/ + HUD note (1,2); empty refined output falls back to raw transcript (3); AX focused-element check before ⌘V, else leave on pasteboard (4); pasteboard restore guarded by changeCount (5); tap removed if engine.start() throws (6); NSLock around sample buffer (7); 2s AXIsProcessTrusted poll retries dead event tap (8); Microphone + Input Monitoring permission rows added (9); LibraryStore.record throws, HUD on save failure (10); response_format=verbose_json for cloud STT language (11); engine+template snapshotted at key-up (12); Keychain SecItemUpdate-then-Add with checked OSStatus (13); fake-engine pipeline contract check in SelfCheck + swift-testing test (14). Verified: swift build green, `SelfCheck PASSED (template seeding, FTS round-trip, pipeline contract)`.

## Round 2 — Codex
8 findings, VERDICT: REVISE. Full text:

> Findings:
> 
> 1. `Sources/FreeTalker/Core/Insertion.swift:54`: Prior finding 4 is not actually fixed; `hasFocusedElement()` accepts any focused AX element, not a focused editable text field, so a focused button/list/window still gets ⌘V and then clipboard restore. Fix: require a writable text-capable AX role/value before posting paste, otherwise leave text on pasteboard.
> 
> 2. `Sources/FreeTalker/Core/Insertion.swift:37`: Prior finding 5 is still present; `changeCount` only detects writes, not whether the target app has read the pasteboard, so slow paste consumers can still receive the restored old clipboard after 0.3s. Fix: avoid timed restore unless paste completion is known, or leave dictated text on pasteboard/manual restore.
> 
> 3. `Sources/FreeTalker/AppCoordinator.swift:122`: Prior findings 1/2 are only partially fixed; `saveFailedAudio()` can fail, but the caller still shows “audio saved” unconditionally. Fix: make recovery save return/throw and only show “audio saved” with a confirmed file URL.
> 
> 4. `Sources/FreeTalker/AppCoordinator.swift:177`: Failed-audio filenames use whole seconds, so two failed dictations in the same second overwrite each other. Fix: use UUID or nanosecond timestamp filenames.
> 
> 5. `Sources/FreeTalker/AppCoordinator.swift:192`: Prior finding 3 is fixed only for normal dictation; Re-process can still accept an empty post-processor result and insert/record empty text instead of falling back to the original Transcript. Fix: apply the same trimmed-empty fallback in `reprocess`.
> 
> 6. `Sources/FreeTalker/AppCoordinator.swift:149`: The terminal HUD messages for manual paste and library-save failure are immediately hidden by the `defer` at lines 112-114, so the user likely never sees the required notification. Fix: do not run unconditional `hud.hide()` after terminal error/manual-paste messages, or delay it after those messages.
> 
> 7. `Sources/FreeTalker/UI/SettingsView.swift:96`: Prior finding 13 is only half fixed; `Keychain.set` returns failure now, but both Settings callers ignore it, so the UI can appear to save a key that was rejected. Fix: handle `false` with visible error state and keep/restore the last persisted value.
> 
> 8. `Tests/FreeTalkerTests/FreeTalkerTests.swift:45`: Prior finding 14 is not really fixed; this test manually calls a fake engine and writes a DB row, but never exercises `AppCoordinator.runPipeline`, insertion fallback, post-processing fallback, or a canned WAV transcription path. Fix: expose an injectable pipeline unit and test fake STT/postprocessor through the actual pipeline contract, or add the specified canned WAV -> transcript check.
> 
> I did not run build/tests because this session is read-only and those commands would write build artifacts.
> 
> VERDICT: REVISE
### Claude's response (round 2)
Accepted 3,4,5,6,7 fully; 1,2,8 with arbiter modifications (logged reasons): (1) permissive AX editability heuristic — skip paste only when AX affirmatively reports non-text focused element; strict role matching rejected because it breaks Electron/web paste targets. (2) timed pasteboard restore kept (1.0s + changeCount guard) — abandoning restore rejected; residual race accepted for personal use, upgrade path = Settings toggle. (3→) saveFailedAudio returns URL?, HUD honest on failure. (4) UUID-suffixed failed-audio filenames. (5) reprocess got same empty-refined fallback. (6) HUD flash(_:duration:) keeps terminal notices visible 2.5s. (7) Settings shows inline Keychain save errors. (8) extracted injectable AppCoordinator.processDictation exercising real transcribe→post-process→insert→record contract with fakes in SelfCheck + tests; real-Whisper canned-WAV check rejected (model download in a unit check). Verified: build green, SelfCheck PASSED incl. pipeline contract + empty-fallback.

## Round 3 — Codex
VERDICT: APPROVED. "No blocking findings." Codex verified round-2 fixes in code and judged the three modified resolutions sound for the personal-use PLAN (permissive AX heuristic, 1s timed restore tradeoff, fake-engine injectable pipeline test). Reconciliation reached in 3 rounds (cap 5).
