# Plan: FreeTalker — system-wide dictation app for macOS
_Locked via grill-with-docs — by Claude + Bruno. Terms per CONTEXT.md._

## Goal

A macOS menu-bar app mimicking Wispr Flow: hold a push-to-talk key anywhere, speak (English or Brazilian Portuguese, auto-detected), release — the Transcript is post-processed by the Active Template and the Refined Output is inserted at the cursor of the frontmost app. All Dictations land in a searchable local Library that supports Re-processing with a different Template. Local-first: on-device Whisper transcription and on-device Apple post-processing by default; cloud engines only via BYOK. Personal use, own Mac (macOS 26), no App Store.

## Approach

1. **Project skeleton.** Swift/SwiftUI menu-bar app (`MenuBarExtra`), macOS 26 target, Xcode project, no sandbox. Info.plist mic-usage string. Menu bar shows: Active Template picker, engine/status, Library window, Settings window, Quit.
2. **Push-to-talk.** Global event tap (CGEventTap) for a configurable hold key (default Right-⌥). Key down → start mic capture (AVAudioEngine, 16 kHz mono); key up → stop, hand audio buffer to pipeline. Minimal floating HUD (small NSPanel pill) visible while recording and while processing. Requires Accessibility + Input Monitoring + Microphone permissions; Settings surfaces grant status with "open System Settings" buttons.
3. **Transcription Engine.** Protocol `TranscriptionEngine` with two implementations:
   - `WhisperKitEngine` (primary): WhisperKit SPM package, `large-v3-turbo` model, downloaded on first run with progress UI; language auto-detect per Dictation; batch (transcribe on key release, no streaming in v1).
   - `CloudSTTEngine` (optional): OpenAI-compatible `/audio/transcriptions` endpoint, BYOK (base URL + key in Settings, key in Keychain).
4. **Post-Processor.** Protocol `PostProcessor` with two implementations:
   - `AppleFMProcessor` (default): Foundation Models framework (`LanguageModelSession`), prompt = Template text + Transcript, output language = Transcript language.
   - `CloudLLMProcessor` (optional, BYOK): Anthropic Messages API or OpenAI-compatible chat endpoint; per-Template flag "use cloud model".
   - Clean Dictation template may run in "light" mode (punctuation/filler cleanup only). A failure in post-processing falls back to inserting the raw Transcript — never lose the user's words.
5. **Templates.** Four built-ins seeded as editable records (Clean Dictation default, Refined Message, Refined Prompt, Email). Template = name + prompt text + cloud flag. CRUD UI in Settings. Active Template switched from menu bar.
6. **Insertion.** Save current pasteboard → write Refined Output → synthetic ⌘V via CGEvent → restore pasteboard after short delay. If the frontmost app rejects paste (no focused text field detectable via AX API), leave text on pasteboard and notify via HUD.
7. **Library.** SQLite (raw sqlite3, thin Swift wrapper) with FTS5 over Transcript + Refined Output. Row: id, timestamp, language, template name, transcript, refined output, engine used. Library window: reverse-chron list, search field, copy buttons, "Re-process with…" template menu (reuses pipeline, appends a new entry linked to the source). Audio not retained.
8. **Verification.** Each stage leaves one runnable check: pipeline unit test (canned WAV → non-empty Transcript), FTS search test, and a manual end-to-end script in the README (dictate into TextEdit in EN and PT).

## Key decisions & tradeoffs

- **Whisper over native SpeechAnalyzer** — best pt-BR accuracy; engine protocol keeps native ASR addable later. See ADR-0001.
- **Local-first, BYOK for anything cloud** — privacy + zero running cost by default; cloud only where the user opts in with own key.
- **Single Active Template, no per-dictation picker** — keeps dictation instant; per-app auto-selection deferred.
- **Batch transcription (on key release)** — no streaming complexity in v1; PTT utterances are short so latency stays acceptable.
- **Paste-based insertion with pasteboard restore** — the only mechanism that works across virtually all apps; AX-based typing is flakier. Known cost: briefly touches the clipboard.
- **Personal use, unsandboxed, no notarization ceremony** — fastest path to daily use; hardening deferred until shared.

## Risks / open questions

- Apple Foundation Models quality for pt-BR restructuring is unproven — if weak, per-Template cloud flag is the escape hatch.
- Fn-key interception conflicts with system dictation settings — default hotkey is Right-⌥, user-configurable.
- Whisper `large-v3-turbo` latency on long holds (>1 min) may feel slow; acceptable for v1, streaming is the v2 lever.
- Pasteboard restore races with clipboard managers — accepted for personal use.

## Out of scope

- App Store distribution, notarization, auto-update.
- Streaming/live transcription preview.
- Per-app automatic Template selection, template variables/sharing.
- Audio retention, tags, export, sync.
- Languages beyond EN and pt-BR.
