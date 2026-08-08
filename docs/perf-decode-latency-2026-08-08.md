# Where dictation time actually goes — 2026-08-08

Third pass on dictation latency, after `perf-dictation-latency-2026-07-29.md` (fallback storm,
two-phase insertion) and `perf-decoder-prompt-2026-08-01.md` (vocabulary prompt tokens). Those two
closed the cases they measured; this one asks what is left, on both legs the request named — local
decode and LLM refinement.

Everything below is measured on this machine, `large-v3_turbo`, release build, warm model, against
real captured audio. Where a number is unmeasured it says so.

## The measurement problem, and what replaced it

`stage timings` and `language detection took` are emitted at persisted log levels, but the app had
not run since 2026-08-06, so the unified log held no production samples in the window — only
test-suite rows with `engine=Spy`. Production stage splits still need a real run (see
"What is still unmeasured").

Two substitutes carried the analysis:

- **The preserved capture corpus** — `~/Library/Application Support/FreeTalker/failed-dictations`,
  4 distinct clips over 1 s, 39.4 s of audio. Biased toward problem audio (they are failures) and
  its longest clip is 18.2 s.
- **Bruno's own dictation history** — `library.db`, `dictations.duration_secs`, 106 rows:

  | bucket | dictations | audio seconds |
  |---|---|---|
  | < 3 s | 6 | 12 |
  | 3–10 s | 29 | 170 |
  | 10–30 s | 38 | 708 |
  | 30–60 s | 16 | 709 |
  | 60–120 s | 15 | 1222 |
  | 120 s+ | 2 | 422 |

  Mean 30.6 s, max 299.9 s. **72.6 % of all transcribed audio seconds are in dictations of 30 s or
  more** — past Whisper's single 30 s window — while **73 of 106 dictations by count are under
  30 s**. Both denominators matter and they point at different fixes, so every number below says
  which regime it belongs to.

## Local decode

### 1. The separate language-detection pass costs a constant 0.31 s

`WhisperKitEngine.performTranscribe` calls `kit.detectLangauge(audioArray:)` and then
`kit.transcribe(...)`. Both compute a log-mel spectrogram and run the audio encoder; WhisperKit's
own `TranscribeTask` instead detects the language *from the encoder output it already has*
(`TranscribeTask.swift`, `decodeWithFallback`). So the encoder runs twice per dictation.

`measureLanguageDetectionCost`, per clip — `detect` is timed around its own call, never differenced:

| audio | detect | pinned decode | two-pass total | one-pass | language (constrained/unconstrained) | text match |
|---|---|---|---|---|---|---|
| 18.193 s | 0.314 s | 1.801 s | 2.115 s | 1.807 s | en / **nl** | no |
| 16.391 s | 0.308 s | 1.656 s | 1.964 s | 1.688 s | pt / pt | yes |
| 2.998 s | 0.310 s | 1.266 s | 1.576 s | 1.191 s | pt / **en** | no |
| 1.786 s | 0.309 s | 8.505 s | 8.814 s | 7.802 s | en / **es** | no |

0.309–0.314 s across a 10× spread of audio length: constant, as the padded-30 s-window reasoning
predicts. That is **~20 % of a 3 s dictation, ~15 % of an 18 s one, and ~0.3 % of a 90 s one**.

**The cheap version of this fix is dead, by measurement.** Letting WhisperKit detect internally
(one encoder pass instead of two) is worth 0.31 s but picked a *different language on 3 of 4 clips*
— Portuguese speech decoded as English, English as Dutch and as Spanish. That is exactly the
misfire the comment at `WhisperKitEngine.swift:556-561` describes, and it is why the constrained
detect exists. The 0.31 s is the ceiling on a fix that constrains the winner to the configured
Dictation Language Set, and WhisperKit's `transcribe()` accepts no precomputed encoder output, so
that fix does not exist in the API as it stands.

What remains is moving the pass **off the critical path** rather than removing it, and it splits
into two changes with very different risk:

**1a — reuse the resolved language across preview ticks (no behaviour change, ship it).** The
live-preview lane calls `whisperEngine.transcribe(… forcedLanguage: nil, candidateLanguages: …)`
every 1.5 s (`livePreviewTickInterval`), so *every tick pays the same 0.31 s detect*. Caching the
resolved language for the recording and passing it to later ticks removes ~0.31 s of ANE work per
tick — roughly 20 % of each tick's cost, and on a 60 s recording about forty ticks' worth of
duplicated detection. Preview output is throwaway and superseded within 1.5 s, so nothing the user
sees changes, and the final decode is untouched. This is the only candidate in this document that
is both meaningful and risk-free.

**1b — also hand that cached language to the final decode.** Worth the full 0.31 s off stop→text,
which is ~20 % of a 3 s dictation. But it decides the dictation's language from earlier audio
rather than from the full recording, so it needs sign-off before it ships.

### 2. VAD chunking is 1.7× slower — do not enable it

The app leaves `DecodingOptions.chunkingStrategy` nil, so audio longer than one window decodes as
sequential 30 s windows. WhisperKit's `.vad` strategy instead splits at voice-activity boundaries
and decodes the chunks concurrently (`concurrentWorkerCount` = 16 on macOS), which looks like the
obvious win for the 72.6 %.

Measured on the corpus concatenated to length — synthetic, but both arms decode identical samples:

| audio | arm | wall | realtime factor | results | loops | windows | fallbacks |
|---|---|---|---|---|---|---|---|
| 96.9 s | sequential | 14.581 s | 0.150 | 1 | 326 | 4 | 1 |
| 96.9 s | `.vad` | 25.361 s | 0.262 | 5 | 35 | 1 | 0 |
| 30 s | sequential | 5.248 s | 0.175 | 1 | 115 | 2 | 2 |
| 30 s | `.vad` | 18.193 s | 0.606 | 1 | 427 | 2 | 2 |
| 60 s | sequential | 23.731 s | 0.396 | 1 | 554 | 3 | 2 |
| 120 s | sequential | 27.258 s | 0.227 | 1 | 628 | 5 | 2 |
| 300 s | sequential | 58.821 s | 0.196 | 1 | 1346 | 12 | 2 |
| 300 s | `.vad` | 94.419 s | 0.315 | 15 | 35 | 1 | 0 |

**`.vad` is slower at every length measured** — 3.5× at 30 s, 1.74× at 97 s, 1.6× at 300 s — idle,
with no live preview competing. The mechanism is in the counters: VAD splits the input into chunks
and each chunk is padded to its own full 30 s window, so at 97 s the encoder ran ~150 s of window
for 97 s of audio against ~120 s sequential. Concurrency across chunks does not pay for the extra
padded encoder work. The transcript got worse too — at 97 s the `.vad` text is 2.5× longer and
loops ("No, no, no, …" repeated), i.e. hallucinating into the padding.

Sequential decode scales roughly linearly at **~0.18–0.23× realtime** (the 60 s point at 0.396 is a
fallback-storm outlier, see finding 3 on how variable that is). The number that matters for the
next finding: **a 300 s dictation costs ~59 s of decode, and every second of it is paid after the
user has stopped talking.**

### 3. Near-silence burns the full fallback budget because WhisperKit's silence verdict is unreachable

The 1.786 s near-silent clip cost 8.5 s in one run and 5.0 s in another, and produced
`"Thank you. Thank. Thank you. Thank you."`. Sweeping `temperatureFallbackCount` on it, twice:

| budget | run A wall / loops | run A text | run B wall / loops | run B text |
|---|---|---|---|---|
| 0 | 0.320 s / 1 | *(empty)* | 0.318 s / 1 | *(empty)* |
| 1 | 0.357 s / 2 | *(empty)* | 9.434 s / 221 | `Thank God. Thank god. I'm glad. I don't know why. …` (500+ chars) |
| 2 (production) | 5.021 s / 114 | `Thank you. Thank. Thank you.` | 0.593 s / 8 | `- -` |

**The cost of a near-silent decode is not a function of the budget — it is a lottery.** Retries
sample at a raised temperature, so the same clip at the same setting cost 0.59 s in one run and
5.02 s in another, and budget=1 cost 0.357 s once and 9.434 s the next time. Only budget=0 is
stable, because it never samples above temperature 0.

That variance is itself the finding: silent or near-silent captures have an unbounded-in-practice
decode cost, 0.3 s to 9.4 s on 1.8 s of audio, and produce invented text when they are slow.
Cutting the budget is still the wrong fix — it is blanket, and it would remove retries from
genuinely hard *real* speech, which is the trade `decodeFallbackBudget`'s doc comment deliberately
refused without a production rate.

The root cause is an ordering issue in WhisperKit. `DecodingFallback.init`
(`Models.swift:377-400`, comment: "NOTE: order matters here") tests
`isFirstTokenLogProbTooLow` **before** the silence branch:

```swift
if isFirstTokenLogProbTooLow {                                   // firstTokenLogProbThreshold
} else if let t = options.noSpeechThreshold, noSpeechProb > t {   // "silence" — needsFallback: false
} else if let t = options.compressionRatioThreshold, … {
} else if let t = options.logProbThreshold, … {
```

On near-silence the first sampled token is exactly what has a terrible log-probability, so the
first branch wins and the decoder retries at a higher temperature before `noSpeechProb` is ever
consulted. WhisperKit already has a "this is silence, stop" verdict; the app never reaches it,
because `firstTokenLogProbThreshold` defaults to -1.5 (`Configurations.swift:211`) and nothing
overrides it.

The tempting one-line fix is to clear `firstTokenLogProbThreshold` so the silence branch becomes
reachable. Reading the source, that flag is not only a fallback trigger; it is also a decode-loop
early exit (`TextDecoder.swift:852-869`):

```swift
let isSegmentCompleted =
    sampleResult.completed || currentTokens.count >= Constants.maxTokenContext - 1 || isFirstTokenLogProbTooLow
if isSegmentCompleted { … break }
```

That early exit is precisely why the budget=0 arm costs 0.318 s at `loops=1`: pass 1 bails after one
token. From that alone the prediction was that clearing the threshold removes the bail and is
*slower*. `measureFirstTokenThresholdCost` measured both arms at the app's real budget (2) over all
four clips and **that prediction did not hold**:

| clip | audio | `-1.5` (default) | `nil` |
|---|---|---|---|
| 12E6C560 (en) | 18.2 s | 1.780 s, 37 loops, 0 fallbacks | 1.780 s, 37 loops, 0 fallbacks |
| 2F97652E (pt) | 16.4 s | 1.638 s, 33 loops, 0 fallbacks | 1.615 s, 33 loops, 0 fallbacks |
| 409FC354 (pt) | 3.0 s | 1.259 s, 24 loops, 0 fallbacks | 1.244 s, 24 loops, 0 fallbacks |
| CBDDCA9C (near-silence) | 1.8 s | 0.592 s, 8 loops, **2 fallbacks**, `- -` | 0.472 s, 5 loops, **0 fallbacks**, `Thank you.` |

Text identical on 3/4. On real speech the flag never fires, so clearing it is inert — that is the
safety evidence, not a win. On the silence clip it does what the source predicted structurally
(`fallbacks=0`, i.e. the silence verdict is now reached) and was 0.12 s *faster*, not slower.

It still ships nothing, for three reasons. The 0.12 s is inside this clip's own noise — the same
clip at the same budget measured 0.593 s in one run and 5.021 s in another. It changes the silence
output from `- -` to a hallucinated `Thank you.`, which is worse: `- -` is more likely to be caught
as junk. And n=1 near-silence clip cannot establish how often either path fires.

The remaining options, none of them shipped here:

- **Raise the threshold** (say -1.5 → -0.5) so the higher-temperature retry also bails. The only
  variant that plausibly makes silence cheap at the app's real budget. It also bails on real speech
  whose first token is merely mediocre, and a bailed pass yields *nothing* — a lost dictation is far
  worse than a wasted 5 s.
- **An app-side speech-presence gate before the decode.** `AudioLevel.peakAndRMS` already exists;
  `AudioCapture.signalFloor` at 1e-7 catches digital zero only, which is why room tone reaches the
  decoder at all. Same lost-quiet-speech risk, with the advantage of being measurable offline.
- **Document it and ship nothing** — what this doc does.

Both active variants need a first-token-logprob or RMS distribution over *real* dictations in both
languages to size the margin. The corpus cannot supply it: every clip in `failed-dictations` is by
definition a failure, n=4, and a threshold that looks safe on four failure clips can silently
truncate real speech.

Consequence worth stating: an empty decode surfaces as `PipelineError.emptyTranscript`
("Transcription failed — audio saved"). For a genuinely silent recording that is the honest
outcome, and it is better than inventing "Thank you." `AudioCapture.isSilentAttempt` does not
already cover this — its `signalFloor` is 1e-7, so it catches digital zero, not room tone, and a
recording with audible-but-wordless noise sails past it into the decoder.

### 4. The largest lever is not a flag — it is decoding while the user is still talking

For a 97 s dictation the app buffers everything and then decodes four windows sequentially **after**
the stop: 14.6 s of measured decode. A 300 s dictation costs 58.8 s over twelve windows. In the
regime holding 72.6 % of Bruno's transcribed seconds, that is the dominant term — larger than every
other finding here combined.

The arithmetic behind "most of it could already be done": decode runs at ~0.18–0.23× realtime, i.e.
roughly 3.6 s per 30 s window, about 8× faster than the audio arrives. On a 97 s recording, window
3's audio is complete at t = 90 s and its decode would finish around t = 93.6 s — before the user
stops. Three of the four windows are genuinely finishable during the recording, leaving only the
last partial window outstanding at stop: **~14.6 s → ~3.6 s**. On the 300 s case, eleven of twelve
windows finish during recording: **~58.8 s → ~5 s**.

This is incremental transcription in all but name, and it is not a small change:

- WhisperKit's `TranscribeTask` advances `seek` from decoded segment timestamps rather than fixed
  30 s slices, so naive fixed slicing would cut mid-sentence. Windows are not independent by
  construction, even though (checked) no cross-window text conditioning is applied.
- The existing streaming lane (`StreamingTranscriptionEngine`, FluidAudio) is English-only
  (`StreamingASRLanguageSupport.supportedLanguages == ["en"]`), so it does not cover Portuguese
  dictations, and it is append-only live insertion rather than a faster batch decode.

Reported as a finding, not attempted here. It is a project, and it lands in the highest-risk area
of the app.

## LLM refinement

### 5. Network transport is not the problem (~50 ms)

The configured provider is `llmProvider = ollama` with `cloudLLMBaseURL = https://ollama.com/v1`,
which `CloudLLMProcessor` serves through `callOpenAICompatible` (`baseURL + chat/completions`).
Three runs against that host: DNS 1.7–14.6 ms, TCP connect 23–35 ms, TLS complete 48.6–60.4 ms. For
comparison, `api.anthropic.com` measured 28–33 ms to TLS complete. Pre-warming the connection at
recording start would buy ~50 ms. Not worth implementing.

### 6. Prompt size is not the problem either

Largest template prompt in Bruno's `templates.json` is 2074 chars (Prompt Engineer (Opus 5)),
typical 550–1100, plus a fixed-rules block and a one-line vocabulary hint. Input is a few hundred
tokens; `refine` is output-token-bound, i.e. proportional to what the user actually dictated.
`max_tokens: 2048` is a ceiling, not a cost.

### 7. Two-phase insertion is deliberately narrow, and correctly so

`shouldUseTwoPhaseInsertion` (AppCoordinator.swift:4013) covers only a cloud post-processor on an
external paste. First question a reviewer will ask — is this user even on that path? Yes:
`case .ollama` is handled *inside* `CloudLLMProcessor` (it routes to `callOpenAICompatible`), so
`processor is CloudLLMProcessor` holds for Bruno's configuration and his external-paste dictations
already get the raw transcript on screen while refinement is still running.

Checked each exclusion against its documented reason rather than assuming the gate was an
oversight: translation would put spoken-language text on screen and could strand it
untranslated; voice commands would strand literal keywords if the replace failed; streaming ASR
already has text on screen; local Apple FM does not pay a variable-latency *network* call. All
intentional. No change proposed.

### 8. On-device refinement pays session setup on the critical path — unmeasured, and not this user's provider

**Applies only to the on-device Apple Foundation Models processor.** Bruno's configured provider is
`llmProvider = ollama`, so `resolveActiveProcessor()` never returns `AppleFMProcessor` for him and
none of this is on his critical path today. Recorded because the code smell is real and the fix is
cheap if the provider is ever switched.

`AppleFMProcessor` builds a fresh `LanguageModelSession(instructions:)` per dictation and
immediately calls `respond(to:)`, so every on-device refinement pays model/session setup after the
transcript is already in hand. `FoundationModels` exposes `prewarm()` for exactly this, and the
useful detail is that `buildProcessorInstructions` depends only on `languagePolicy` and
`voiceCommandPolicy` — **not** on the template, which lives in the user content — so the
instructions are fully knowable at recording start and the session can be built and prewarmed while
the user is still speaking.

This is the local analogue of finding 5, except what is being warmed is a model load rather than a
TLS handshake, so the prize is plausibly seconds rather than milliseconds. Unmeasured: it needs a
run with Apple Intelligence active. If it turns out that local refinement is slow for reasons
*other* than setup, the two-phase gate's Apple FM exclusion (finding 7) is the thing to revisit —
and then the cost predicate belongs on the `PostProcessor` that pays it, declared as a property
defaulting to "no variable latency", not as another `processor is X` clause in the caller.

## Ranking

| # | change | regime it helps | measured effect | verdict |
|---|---|---|---|---|
| 1a | cache the resolved language for the recording, reuse it for later preview ticks | during every recording | ~0.31 s of ANE work per tick, ticks every 1.5 s | **recommended, not implemented** — no user-visible behaviour change, but it edits the live-preview lane and wants its own review |
| 4 | decode completed windows during recording | long dictations (72.6 % of seconds) | ~11 s of 14.6 s on a 97 s dictation; ~44 s of 59 s on a 300 s one | project, high risk — Bruno's call |
| 1b | also hand the cached language to the final decode | short dictations (73/106 by count) | 0.31 s off stop→text | needs sign-off: language decided from earlier audio |
| 8 | prewarm the Apple FM session | on-device refinement only | unmeasured | **not this user's provider** (`llmProvider = ollama`) |
| 3 | anything touching the silence path | silent/near-silent captures | budget 0/1/2 at 0.320 / 0.357 / 5.021 s; clearing the threshold: 0.592 s → 0.472 s on one clip, inert on the other three | document only — the delta is inside this clip's own noise and it worsens the silence output |
| 2 | `chunkingStrategy = .vad` | — | **1.6–3.5× slower at every length** | rejected |
| 5 | pre-warm the cloud connection | — | ~50 ms handshake | rejected |

No row claims a number that no benchmark produced, and row 1a is a recommendation rather than a
delivered change: this branch contains the doc and the benchmarks only, no `Sources/` edit.

**The ranking is conditional on one unmeasured quantity.** Bruno's configured refinement is
`llmProvider = ollama`, `cloudLLMModel = gemma4:31b-cloud` over `https://ollama.com/v1` — a 31 B
model on a cloud endpoint. For a short dictation, `refine=` may well be the largest single term in
`stage timings`, larger than the whole decode the findings above optimize. Nothing here can settle
that without a production run.

## What is still unmeasured

- **Production stage splits.** `transcribe=` vs `refine=` on real dictations. Needs the app running:
  2 short English (~5 s), 1 Portuguese (~10 s), 1 long (60 s+), and 1 deliberately silent (start,
  say nothing ~3 s, stop). Then
  `log show --last 30m --predicate 'eventMessage CONTAINS "stage timings" OR eventMessage CONTAINS "decode quality" OR eventMessage CONTAINS "language detection took"'`.
- **Temperature-fallback frequency in production.** Not recorded in `library.db` (checked:
  `dictations`, `transcription_jobs`, `job_attempts` and `transcript_segments` carry no decode-quality
  fields), and the unified log had no `decode quality` rows in the window. Finding 3 rests on one
  clip for frequency, though its mechanism is confirmed in WhisperKit's source.
- **Finding 8's prize**, which needs the Apple FM provider selected and Apple Intelligence active.
  Deliberately not measured: it is not this user's provider, so pricing it would mean changing his
  configuration to benchmark a path he does not use.

## Benchmarks

All env-gated and excluded from the suite, in `Tests/FreeTalkerTests/DecodePromptBenchmark.swift`:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer FREETALKER_LANGDETECT_BENCH=1 \
  swift test -c release --filter measureLanguageDetectionCost
DEVELOPER_DIR=… FREETALKER_CHUNKING_BENCH=1   swift test -c release --filter measureChunkingAndFallbackCost
DEVELOPER_DIR=… FREETALKER_FIRSTTOKEN_BENCH=1 swift test -c release --filter measureFirstTokenThresholdCost
```

### Limitations

- The corpus is `failed-dictations`: biased toward problem audio, and no clip reaches 30 s. The
  length sweep concatenates it to reach the multi-window regime, so its transcripts are nonsense —
  only the wall-clock comparison between arms is meaningful there.
- `measureLanguageDetectionCost` omits `promptTokens` on both arms, so the delta survives but
  absolute decode times understate the Raw/skip-post-processing path. For the cloud-refined path
  the no-prompt arm *is* production shape, because `decoderBiasVocabulary` already withholds the
  bias when refinement will carry the vocabulary anyway.
- Arms run in fixed order within a clip, so a small delta between arms is not distinguishable from
  ordering noise. Findings here rest on directly timed quantities (finding 1) or on deltas large
  enough that ordering cannot explain them (finding 2, and the budget sweep in finding 3). The
  0.12 s threshold delta in finding 3 is explicitly *not* one of those, which is why it ships
  nothing.
