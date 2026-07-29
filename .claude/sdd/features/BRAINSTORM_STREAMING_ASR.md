# BRAINSTORM: Streaming ASR (type-as-you-speak)

**Phase:** 0 — Brainstorm
**Date:** 2026-07-24
**Status:** Ready for `/define`
**Feature slug:** `STREAMING_ASR`

---

## Problem

FreeTalker's dictation is batch: you hold the key, speak, release, wait, text appears.
"Live preview while recording" (`AppCoordinator.swift:2593-2674`) is a polling loop that
re-decodes the last 12 s of audio with WhisperKit every 1.5 s and renders the result into
FreeTalker's own HUD/Scratchpad — it never reaches the target application.

Competing dictation products (Wispr Flow, Aqua Voice) win on *perceived* latency, not
accuracy: words appear in the field while you are still speaking. That is the single
largest felt gap in the product today.

---

## Context discovered

| Fact | Evidence |
|------|----------|
| FluidAudio **0.15.5** already pinned (for diarization) and ships a full streaming ASR API | `Package.resolved`; `.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/` |
| `StreamingAsrManager` protocol: `appendAudio(_:)`, `processBufferedAudio()`, `setPartialTranscriptCallback(_:)`, `finish()`, `reset()` | `ASR/Parakeet/Streaming/StreamingAsrManager.swift:20` |
| Concrete actors: `StreamingEouAsrManager`, `StreamingNemotronAsrManager`, `SlidingWindowAsrManager` (has `configureVocabularyBoosting`) | `Streaming/EOU/…:163`, `Streaming/Nemotron/…:10`, `SlidingWindow/SlidingWindowAsrManager.swift:10` |
| WhisperKit 0.18.0 also has `AudioStreamTranscriber` + `TranscriptionCallback` | `Core/Audio/AudioStreamTranscriber.swift:23`, `Core/Models.swift:732` |
| `AudioCapture` owns one `[Float]` buffer under `NSLock`; engine only ever sees bounded suffix copies — **no live tap fan-out exists** | `Core/AudioCapture.swift:147,187,384,411-432` |
| Insertion is **pasteboard + synthesized ⌘V** with save/restore; AX used only to *verify* the target, never to set a value | `Core/Insertion.swift:91,144-147,309-324` |
| **No mechanism to replace previously inserted text** | `Core/Insertion.swift` — `insert()` is one-shot, no ledger, no range tracking |

**Net:** no new dependency is required. The obstacle is not ASR — it is that the output path
can only append once.

---

## Decisions (from discovery)

| # | Question | Decision |
|---|----------|----------|
| 1 | Where do partials appear? | **Live into the target field**, replaced by refined text on release |
| 2 | Languages the streaming engine can't do? | **Silent fallback** to today's batch path — worst case is current behaviour |
| 3 | How does raw become refined? | **Append-only partials, then `⌫ × N` + repaste** the refined text |
| 4 | Validation material? | **Replay existing Library + Recoveries audio** against stored WhisperKit transcripts |

---

## Selected approach — A: additive streaming lane

Existing batch pipeline stays byte-identical and is the fallback. Three new pieces:

### 1. Live tap fan-out
`AudioCapture.consume(buffer:)` gains an optional live-sample callback. The existing
`samples` accumulation is untouched, so post-processing, Library, Recoveries and the
crash-safe journal all keep working exactly as today.

### 2. `StreamingTranscriptionEngine`
New protocol alongside `TranscriptionEngine`, backed by FluidAudio's `StreamingAsrManager`.
Receives live PCM, emits **confirmed prefixes only** (never rewrites already-emitted words —
this is what makes append-only possible, and what the current polling preview cannot do).
Existing vocabulary list feeds `configureVocabularyBoosting`. Parakeet CoreML model
download/delete reuses `SpeechModelStore`'s existing UI.

### 3. `LiveInsertionSession`
Owns a **grapheme-cluster ledger** of everything typed. Emits text via
`CGEvent.keyboardSetUnicodeString` — typing, not pasteboard, so the clipboard is not
thrashed dozens of times per recording and does not fight the restore timer at
`Insertion.swift:144`.

On stop:

| Action | Behaviour |
|--------|-----------|
| Done (✓) / key release | `⌫ × ledger.count`, then existing `Insertion.insert()` with the refined text |
| Raw | `⌫ × ledger.count`, paste the raw transcript |
| Cancel (✕) | `⌫ × ledger.count`, insert nothing |

### Rejected alternatives

**B — extend the 12 s polling preview to insert into the target.** Re-decoding a rolling
window rewrites earlier words, so append-only is impossible; every tick would need
delete-and-retype. Rejected.

**C — Parakeet replaces WhisperKit wholesale.** Loses the curated 8-language coverage
(`Models/DictationLanguage.swift:9-17`) and the import/diarization path. Contradicts
decision #2. Rejected.

---

## Edge cases (in scope)

- **Language gate** — stream only when the resolved language is explicit *and* supported
  (precedence unchanged: one-shot > app rule > pin). `Auto` → no live insertion, today's HUD
  preview. Removes the first-second detect race for free.
- **Focus drift mid-recording** — stop typing immediately, freeze the ledger, never
  backspace. Refined text goes to the clipboard with a HUD hint. Reuses the drift detection
  at `Insertion.swift:155-221`.
- **Secure fields** — never stream. Reuses the existing editability check.
- **Replace cap** — `⌫ × 2000` is slow and visually violent. Above ~400 grapheme clusters,
  skip the replace entirely: keep the raw typed text, put the refined text on the clipboard.
  `// ponytail: 400-char replace cap, raise if backspace batching proves fast`
- **Cloud STT selected** — batch path, no streaming.

## YAGNI — cut from MVP

| Cut | Why | Revisit when |
|-----|-----|--------------|
| EOU-based auto-stop | FluidAudio exposes it, but it is a distinct feature with its own false-cutoff failure mode | After streaming ships and EOU quality is observed |
| Streaming into Scratchpad | Already has a working preview | If users ask |
| Per-app streaming rules | Decision #1 chose global | If autocomplete hijack proves common |
| Token timestamps / confidence colouring | Cosmetic | Never, probably |
| Streaming for media imports | Offline, no latency problem | Never |

## Accepted risk

Apps with aggressive autocomplete (Slack `@`-mention popups, IDE completion) may hijack
typed keystrokes. Mitigation is a kill switch (Esc / toggle), not prevention. If this
proves common in practice, the per-app allowlist above is the designed escape hatch.

---

## Validation harness (grounding)

Replay every Library/Recoveries entry that still has audio on disk through the streaming
engine offline, and diff against the stored WhisperKit transcript:

```
for each entry with kept audio:
    stream(audio) → partial timeline + final text
    diff(final, stored_transcript)
report: WER, first-partial latency, final-vs-release lag
```

Real voice, real mic, real EN/PT mix, zero manual labelling. This is the one runnable check
the feature must leave behind — it fails if Parakeet regresses accuracy or the partials stop
being append-only.

---

## Draft requirements for `/define`

1. Partial transcript text appears in the focused field while the user is still speaking,
   for explicitly-resolved supported languages.
2. Partials are append-only; already-emitted characters are never rewritten mid-recording.
3. On stop, previously typed characters are removed and replaced by the post-processed
   output, unless the ledger exceeds the replace cap or the insertion target has drifted.
4. Cancel removes all typed characters and inserts nothing.
5. Unsupported language, `Auto` language, cloud STT engine, or secure field → existing batch
   behaviour, unchanged.
6. The existing batch path, Library, Recoveries and crash-safe journal are unaffected.
7. No new package dependency.
8. A replay harness reports WER and first-partial latency against stored Library transcripts.

---

**Next:** `/define .claude/sdd/features/BRAINSTORM_STREAMING_ASR.md`
