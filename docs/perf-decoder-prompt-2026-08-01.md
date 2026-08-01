# Decoder prompt latency — 2026-08-01

Follow-up to `perf-dictation-latency-2026-07-29.md`, which closed the long-dictation case and left
"small dictations still feel slow" unexplained. The cause is the vocabulary bias the app sends to
WhisperKit as `promptTokens`: for a 6 s dictation it was **more than half the decode**, and it is
paid again on every live-preview tick while the Recording runs.

## What the log said

`stage timings` (added 2026-07-31) across a day of real dictations, with `decode timings` from the
still-resident info buffer:

| Audio | transcribe | loops | generated tokens | decodeLoop |
|---|---|---|---|---|
| 5.63 s | 2.76 s | 55 | 14 | 2.50 s |
| 5.89 s | 3.06 s | 61 | 20 | 2.75 s |
| 6.66 s | 3.11 s | 65 | 24 | 2.92 s |
| 64.00 s | 8.81 s | 187 (3 windows) | 35 + 40 + … | 8.51 s |

Every loop costs ~45 ms, and `loops − generated` is a constant ~41 per window — the same 41
regardless of how much was actually said.

## Root cause

41 is the token length of the user's vocabulary list. `VocabularyFitGate.serializedPrompt` joins
the terms, `WhisperKitEngine.performTranscribe` encodes them into `options.promptTokens`, and
WhisperKit's `TextDecoder` main loop then runs **one full decoder inference per prompt token, per
30 s window** — the prefill iterations call `predictLogits` exactly as generated tokens do
(`TextDecoder.swift`'s `for tokenIndex in prefilledIndex..<loopCount`). A non-nil `promptTokens`
additionally disables the KV prefill cache (`usePrefillCache` is guarded on
`promptTokens == nil`), so the task/language prefill is re-run token by token as well.

So the vocabulary is not a hint the decoder consults — it is decoder work, priced per token, per
window, on every dictation and every preview tick.

## Measured, on real captured audio

`Tests/FreeTalkerTests/DecodePromptBenchmark.swift` (env-gated, not part of the suite) against
`last-dictation.wav` with the live 13-term vocabulary, `large-v3_turbo`, warm:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer FREETALKER_DECODE_BENCH=1 \
  swift test --filter DecodePromptBenchmark
```

| Case | with prompt | without prompt | |
|---|---|---|---|
| 6 s slice, 1 window | 1.53 s, 30 loops | **0.62 s, 8 loops** | −0.91 s, 2.5× |
| 64 s, 3 windows | 8.62 s, 187 loops | **4.20 s, 79 loops** | −4.42 s, 2.05× |

The vocabulary serializes to exactly 41 prompt tokens, confirming the log arithmetic. Encoder cost
is unchanged (0.26 s / 0.77 s) — this is all decode.

### What it costs in accuracy

Both transcripts of the 64 s sample spell the vocabulary term in it (`Codex`) correctly. The
differences are formatting and verbatim fidelity, which is what the prompt's "condition on previous
text" behaviour actually influences here:

- with prompt: `… I need you to evaluate it and try to optimize this time. Faster than it currently is at least by 10% …`
- without: `… I need to evaluate it and try to optimize this time. it should be faster than it currently is at at least by 10% …`

That gap is precisely what the post-processing pass is for. Note also that on the 6 s slice the
prompted decode returned **empty text** while the unprompted one returned words — on short audio
the prompt is not reliably an improvement at all.

## The change

`AppCoordinator.decoderBiasVocabulary` withholds the bias only when it actually buys latency —
which needs **both** an engine that pays decode time for it and a downstream pass that carries the
terms anyway:

| Path | Carries vocabulary downstream | Bias |
|---|---|---|
| Refine (cloud or Apple FM) | `PostProcessingRequest.vocabulary` → `vocabularyInstruction` | withheld |
| Translate | same, via `TranslationService` | withheld |
| Recovery retry | same (always post-processes) | withheld |
| Raw (`skipPostProcessing`) | nothing | **kept** |
| Live preview tick | nothing — text is display-only, superseded every 1.5 s | withheld |
| **Any of the above on Cloud STT** | — | **kept** |

The engine dimension came out of Codex's adversarial review and is the reason the predicate is not
just "will something else carry it". `CloudSTTEngine` sends the terms as a multipart `prompt` field
on a request it was already making: nothing to save, so withholding there would have been a pure
feature loss for every refined/translated Cloud-STT dictation. Engines answer for themselves via
`TranscriptionEngine.vocabularyBiasCostsDecodeTime`, defaulting to `false` so a future engine keeps
the feature until it declares a reason not to.

Plus two smaller ones:

- `WhisperKitEngine.predeterminedLanguage` skips the language-detection pass (~0.33 s, its own
  logmel+encoder run) when the Dictation Language Set has one entry. An equivalence, not a
  heuristic: `constrainedLanguage` is an argmax restricted to the candidate set, so a one-element
  set resolves to that element for every distribution detection could return. Bruno's set is
  `["en", "pt"]`, so this changes nothing for him.
- `decode timings` / `decode quality` / `language detection took` moved from `info` to `notice`.
  Info-level messages are evicted from the in-memory buffer within hours, which is why the
  2026-08-01 08:30 storm (1.79 s of audio → 15.24 s of decode) could not be diagnosed after the
  fact while `stage timings` for the same dictation had survived.

### Expected end-to-end

For the 5.4 s dictation measured at 21:52 on 2026-07-31 (stop → text 3.82 s = 0.33 detect + 2.4
decode + 0.53 refine + ~0.3 pipeline overhead), the decode term drops to ~0.6 s: **~2.0 s, ~1.9×**.
Not verified on the live app — that needs a real dictation through the mic.

## What this does not fix

- **The fallback storm.** 2026-08-01 08:30 spent 15.24 s on 1.79 s of audio on a build that already
  had `decodeFallbackBudget = 2`; three passes at the then-current ~2.5 s each is ~7.5 s, so roughly
  half of it is still unexplained and its `decode timings` line no longer exists. The prompt change
  shrinks each pass (~2.5 s → ~0.9 s here) so a storm costs proportionally less, but its root cause
  is still unknown. The `notice` promotion above is what will make the next occurrence diagnosable.
- **Model choice.** `whisperModelChosen` is still 0 — nothing ever deliberately picked
  `large-v3_turbo` (954 MB). The catalog's 632 MB turbo variant is still unmeasured; it is not
  downloaded on this machine.
- **Stage overlap.** Journal finalize → durable registration → library refresh → window OCR → STT
  are still serial before the decode. Measured at ~0.3 s combined on 2026-08-01, so there is little
  left to win there — but window OCR's output is still discarded by the post-processor whenever a
  cloud LLM is configured (`perf-dictation-latency-2026-07-29.md`, secondary findings).
