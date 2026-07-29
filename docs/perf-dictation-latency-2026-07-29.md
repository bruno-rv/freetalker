# Dictation latency investigation — 2026-07-29

Reference case: dictation id=115 (library.db), 2026-07-29 08:21:30, pt, 91.99 s of audio,
engine WhisperKit, template "Clean Dictation".

## The measured wait

Unified log: `capture stopped: samples=1471906` at 08:20:17.6.
`LibraryStore.record` stamps `ts` with `Date()` at insert time (LibraryStore.swift:128), and the
row's `ts` is 08:21:30.

**Stop → text delivered: ~72 s** for 92 s of speech.

`~/Library/Application Support/FreeTalker/last-dictation.wav` (mtime 08:20, 1471906 frames @ 16 kHz
mono) is that dictation's exact audio, so the stages below were replayed against the real input.

## Stage costs (measured on the real input)

| Stage | Measured | How |
|---|---|---|
| WhisperKit `large-v3-turbo` (the active model), 92 s audio, warm | **18.5 s decode**, RTF 0.20 (+0.87 s model load) | `whisperkit-cli transcribe` on `last-dictation.wav`, `--language pt` |
| Same audio, `openai_whisper-small` | **2.7 s decode**, RTF 0.03 | same command, small variant |
| Post-processing LLM (ollama.com, `gemma4:31b-cloud`) | **1.9 s – 33.3 s** for the identical payload | replayed `openAICompatibleRequestBody` verbatim |
| Window screenshot + Vision OCR (`.accurate`, 2062×1614) | **~1 s** | `VNRecognizeTextRequest` benchmark matching VisionOCRService |

The replayed post-processing response was 794 characters — byte-for-byte the length of the stored
`refined` — confirming the reconstructed payload matches what the app actually sent.

### The accounting has an unresolvable fork

The LLM call for this dictation was either ~2 s or ~33 s; nothing on disk records which. So the
budget is one of:

- LLM hit the slow path: 33 s (LLM) + 19 s (STT) + 1 s (OCR) = 53 s, leaving **~19 s unattributed**.
- LLM hit the fast path: 2 s + 19 s + 1 s = 22 s, leaving **~50 s unattributed**.

A 50 s hole would be a different investigation entirely. **This cannot be closed from existing
evidence** — the pipeline logs no stage durations anywhere. See "What's still open".

## Root cause

The wait is the **sum of serial stages**, with the two large ones being STT and the LLM:

1. **STT is batch-after-stop and its cost scales with recording length.** `performTranscribe`
   decodes the *whole* sample buffer once recording stops (AppCoordinator.swift:3785 →
   WhisperKitEngine.swift:524). Live preview ticks during recording decode only the last 12 s
   (`livePreviewWindowSeconds`) and their output is discarded — no partial result is reused. So
   stop-time cost is `RTF × recording_duration`: 92 s of speech buys ~19 s of waiting *before*
   post-processing begins. A `StreamingTranscriptionEngine` exists in the codebase; this path does
   not use it.

2. **The active model is the slow end of the catalog, and nothing chose it deliberately.**
   `whisperModelChosen = 0` — auto-selection landed on `large-v3-turbo` (954 MB), which measures
   RTF 0.20 here. `openai_whisper-small` transcribes the same audio at RTF 0.03 — **7× faster**, at
   visibly lower accuracy on this Portuguese sample (more garbled proper nouns). This is a real
   accuracy/latency trade, not a free win, but it is the single largest lever on the local half.

   Not a misconfiguration: WhisperKit already defaults both encoder and decoder to
   `.cpuAndNeuralEngine` (Models.swift:103/119), and forcing alternatives is worse or neutral —
   `cpuAndGPU` 46.9 s, VAD chunking with 4 concurrent workers 19.7 s, default 19.8 s. RTF 0.20 is
   what this model costs on this machine.

3. **Post-processing is a variable-latency network dependency, called non-streaming.** The same
   payload to the same model measured 1.9 s and 33.3 s within one 15-minute window (see
   distribution below). `URLSession.data(for:)` with a 300 s timeout (CloudLLMProcessor.swift:112)
   means the app waits for the final token before inserting anything, so every slow draw is paid in
   full by the user. `gemma4:31b-cloud` vs `gemma4:31b` made no difference once warm (~1.9 s each) —
   the suffix is not the variable.

4. **Nothing overlaps.** Journal staging → windowOCR screenshot+OCR → STT → LLM → insertion, all
   sequential on the stop path (AppCoordinator.swift:2453-2501).

### Observed post-processing latency distribution

Identical payload, spaced ~4 min apart:

| Time | Total | Completion tokens |
|---|---|---|
| 08:26 (first calls of the session) | 5.1 s / 24.9 s / **33.3 s** | 20 / 216 / 222 |
| 08:39:59 | 2.9 s | 222 |
| 08:44:01 | 1.9 s | 221 |
| 08:48:04 | 1.9 s | 222 |
| 08:52:05 | 1.6 s | 216 |
| 08:56:07 | 1.8 s | 221 |

Normalized: 0.115–0.253 s/token in the early window vs 0.008–0.013 s/token afterwards — two regimes
~15× apart, with a step change between 08:31 and 08:39 rather than a decaying warm-up curve. Steady
state is ~1.9 s (≈110 tok/s).

The 25–33 s draws all fell inside one ~15-minute window and never recurred across five spaced
samples — so the slow path is real but its frequency is unmeasured, and one sample window can't
establish it. The dictation (08:20–08:21) sits inside that window, where every observation was slow,
which *suggests* it drew the slow path; that is temporal inference, not measurement.

### Secondary findings

- **windowOCR's result is discarded by the post-processor when a cloud LLM is configured.**
  `localContextForProcessor` returns `nil` whenever cloud is configured (AppCoordinator.swift:2632),
  and `transcribeAndRefine` only consumes `localContext` for `AppleFMProcessor`
  (AppCoordinator.swift:3850). With `llmProvider = ollama` the OCR text reaches only
  `resolveContextAwareTemplate` (automatic style selection). At ~1 s it is not a significant latency
  cause — but it is serial hot-path work whose main consumer is switched off.
- **No stage timing exists anywhere in the pipeline.** The app has `Logger` instances but logs no
  durations, which is why the fork above cannot be resolved from data already on disk.
- Machine state during the investigation — 107 MB free pages, 3.16 GB of 4 GB swap used — is context
  only. No measurement here attributes any latency to it.
- The first `whisperkit-cli` run took 132 s, but that was a fresh binary compiling and caching the
  mlmodelc files for the first time. It says nothing about what the running app pays; `preload()`
  loads the model at launch.

## What would actually shorten the wait

Ordered by measured payoff:

1. ~~**Insert the raw transcript immediately, then replace it with the refined text when it lands**~~
   — **implemented by a concurrent session on 2026-07-29, uncommitted; the symbols exist but this
   investigation did not verify the behaviour or run its tests** (`AppCoordinator.shouldUseTwoPhaseInsertion`, `Insertion.
   insertEarlyTrackingCorrection`/`replaceEarlyInsertion`, `TwoPhaseInsertionTests`). Text now
   reaches the document when STT finishes; the refinement replaces it in place through the
   Correction Loop's existing select-then-paste path. Gated to the cloud-post-processed external
   paste only — Raw, local Apple FM, translation and streaming ASR still insert exactly once.
   Given the distribution above this usually saves ~2 s and its real value is bounding the 33 s
   tail, not a guaranteed 30 s win.

   Two-phase limitations, all deliberate:
   - **Cancel/failure after phase 1 leaves the raw transcript in the document.** The recovery
     entry is still created (audio preserved) and its HUD says so; retrying that recovery pastes
     the refined text *next to* the raw one rather than over it, since the retry path runs
     single-phase (`earlyInsertion: nil`).
   - **Clipboard.** Both pastes suppress `insert`'s own timed restore (a sub-second
     post-processing round trip would otherwise make phase 2 "restore" phase 1's raw transcript
     over the user's clipboard). The clipboard is snapshotted once before phase 1 and given back
     exactly once: by phase 2's paste, or by `Insertion.restoreEarlyInsertionClipboard` when no
     phase 2 paste runs (refinement came back byte-identical, or the pipeline threw between the
     phases). The one deliberate exception is `.rawLeftInPlace`, where the refined text is meant
     to stay on the clipboard for a manual paste. The window during which a manual ⌘V yields the
     raw transcript is now post-processing + 1.0 s rather than 1.0 s — up to ~31 s on a slow draw.
     The `changeCount` guard protects a user *copy* in that window, not a user *paste*.
   - **Correction Loop state.** A throw between the phases also runs
     `RecentInsertionStore.invalidateAll()`: `record()` never fires on that path, so phase 1's
     pending snapshot would otherwise be promoted under the *next* dictation's id.
   - **Untested at the AX layer.** The pipeline gating and delivery accounting have unit tests
     (`TwoPhaseInsertionTests`, spy-injected); `insertEarlyTrackingCorrection` /
     `replaceEarlyInsertion` themselves need a live session, so the raw→refined swap landing as a
     replacement rather than an append is verified only by real dictation.
2. **Reconsider the speech model.** small is 7× faster on the same audio; the catalog also has
   `large-v3-turbo (632 MB)` between the two, unmeasured. Since `whisperModelChosen = 0`, this was
   never a deliberate choice.
3. **Reuse streaming/incremental STT** so stop-time work is only the tail, instead of re-decoding
   the full buffer.
4. **Overlap STT with the OCR/journal stages** rather than running them in series.
5. **Add stage-duration logging** — needed to resolve the accounting fork and to notice regressions.

## What's still open

The unattributed 19 s or 50 s. Closing it needs one of:

- stage-duration logging in the pipeline, then one dictation; or
- two similar-length dictations back to back — if the second is much faster, the residual is
  cold/paging/contention rather than steady-state cost.

## Reproduction commands

```sh
# STT on the real audio (build whisperkit-cli in .build/checkouts/WhisperKit first)
.build/release/whisperkit-cli transcribe \
  --model-path ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3_turbo_954MB \
  --audio-path ~/Library/Application\ Support/FreeTalker/last-dictation.wav --language pt --verbose

# Post-processing payload replay: rebuild the body per
# CloudLLMProcessor.openAICompatibleRequestBody and POST to https://ollama.com/v1/chat/completions
```
