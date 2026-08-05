# Delivering audio as MP3 instead of WAV — 2026-08-05

Evaluation of the question "can we send MP3 instead of WAV to speed up transcription?"

**Short answer: MP3 is the wrong lever, and for the default configuration it is not a lever at all.**
Only one code path uploads audio anywhere, it is opt-in, and the measured bottleneck is not the
bytes. Where compression *does* help, MP3 is the worst of the available codecs on this platform.

## Where audio is "delivered" today

Capture produces one in-memory `[Float]` — 16 kHz, mono, Float32
(`Core/AudioCapture.swift:235`, `:1147`, `:713`). Four consumers:

| Consumer | Form | Encoded? |
|---|---|---|
| **Cloud STT upload** (`Engines/CloudSTTEngine.swift:52`) | 16-bit PCM WAV in a multipart body | **yes — the only encode** |
| Local WhisperKit (`Engines/WhisperKitEngine.swift:619`) | `kit.transcribe(audioArray: samples)` | no — floats, in memory |
| Recovery journal (`Workflows/Recovery/CaptureSegmentCodec.swift`) | Float32 PCM WAV on disk | n/a — durability format |
| Media import (`Workflows/Media/PCMWAVFileWriter.swift`) | decodes mp3/m4a/mp4 **into** WAV | n/a — wrong direction |

`TranscriptionEngine.transcribe` takes `samples: [Float]`, so nothing above the engine layer knows
a container exists. The change surface for a codec swap is three lines:
`CloudSTTEngine.swift:52` (encode) and `:190-191` (`filename="audio.wav"`, `Content-Type: audio/wav`).

### The default configuration uploads nothing

`AppSettings.swift:1005` defaults `sttEngine` to `.whisperKit`, and `activeSTTEngine`
(`AppCoordinator.swift:350-360`) only builds the cloud leg when the user has switched away from it.
On a default install the audio never leaves the machine and never gets encoded at all. **Any
compression work benefits only users who opted into cloud STT.**

## What the compression would actually buy

16 kHz mono 16-bit PCM is 32 000 B/s — 1.92 MB per minute. The reference 92 s dictation from
`docs/perf-dictation-latency-2026-07-29.md` is a 2.94 MB upload.

| Codec | Rate | 92 s dictation | vs WAV |
|---|---|---|---|
| PCM WAV (today) | 32.0 kB/s | 2.94 MB | 1× |
| FLAC (lossless) | ~15–18 kB/s | ~1.6 MB | ~1.8× |
| AAC-LC / MP3 @ 32 kbps mono | 4.0 kB/s | 368 kB | **8×** |

Upload time saved on that dictation, by uplink:

| Uplink | WAV | AAC @32 kbps | Saved |
|---|---|---|---|
| 50 Mbps | 0.5 s | 0.06 s | ~0.4 s |
| 10 Mbps | 2.4 s | 0.3 s | ~2.1 s |
| 2 Mbps | 11.8 s | 1.5 s | ~10.3 s |

Set against the measured stage costs in the latency investigation — 18.5 s of local decode, and a
cloud post-processing call that measured anywhere from 1.9 s to 33.3 s for the same payload — a
0.4–2 s saving on a normal connection is noise. It becomes real only on a genuinely slow uplink,
and it is bounded by upload time, which nothing has yet measured on this pipeline. **No stage
timing exists anywhere in the app** (the same gap that left 19–50 s unattributed in the July
investigation), so today we cannot say what fraction of a cloud dictation is even spent uploading.

### The stronger argument is a ceiling, not a speedup

OpenAI's `/audio/transcriptions` caps requests at 25 MB. At 32 kB/s that is **~13 minutes of
audio**, after which a cloud dictation fails outright. At 32 kbps it would be ~104 minutes.
Separately, `request.httpBody` is assembled whole in memory (`CloudSTTEngine.swift:63`), so a long
dictation holds the WAV and the multipart copy simultaneously.

That is a correctness/robustness win with a defined threshold, and it is a better reason to
compress than latency is.

## Why not MP3 specifically

1. **macOS has no MP3 encoder.** AudioToolbox/AVFoundation ship `kAudioFormatMPEGLayer3` for
   *decode* only; encoding requires a third-party encoder (LAME). Nothing in `Sources/` encodes
   compressed audio today — the single `kAudioFormat*` reference in the whole tree
   (`Workflows/Media/AVAudioDecoder.swift:45-50`) asks for `kAudioFormatLinearPCM`, i.e. AVFoundation
   is used only to decode *into* PCM. `AVAssetExportSession`, `AVAudioRecorder` and
   `AVAudioFile(forWriting:)` appear zero times.
2. **Licensing.** LAME is LGPL. This project is 0BSD (`LICENSE`), with no third-party binary
   dependencies beyond two SwiftPM packages. Bundling an LGPL dylib into a signed, notarized
   `.app` adds relinking obligations that nothing else here carries.
3. **A native codec gets the same 8×.** AAC-LC in an M4A container (`kAudioFormatMPEG4AAC`) is a
   first-party encoder, and `m4a` is on the endpoint's accepted-format list alongside `mp3`. There
   is no size or quality argument for paying MP3's cost to land in the same place.

## Where compression must not go

The recovery journal is not a candidate under any codec. `CaptureSegmentCodec` validates its WAV
header byte-for-byte and rejects anything that isn't Float32/16 kHz/mono/64 000 B-per-s
(`CaptureSegmentCodec.swift:173-197`); segments are recovered by *concatenating* payloads and
hashing header+payload (`:98-144`). That design depends on the container being append-safe,
byte-addressable and lossless — a truncated PCM segment is still recoverable audio, a truncated
lossy frame is not. It also feeds re-transcription (`RecoveryRetryPipeline.loadPCM`), where a lossy
generation loss would cost accuracy on exactly the dictations that already failed once.

Likewise the local engine: it consumes floats directly, so encoding for it would add an
encode/decode round trip and a fidelity loss in exchange for nothing.

## Recommendation

1. **Don't do MP3.** If we compress the upload, use **AAC-LC in M4A** via `AVAudioConverter` +
   `AVAudioFile` — native, no new dependency, no licence change, same 8×.
2. **Don't do it for latency first.** Do it for the 25 MB / ~13-minute ceiling and the in-memory
   body. Frame it that way, and pick the bitrate for accuracy headroom rather than for size.
3. **Measure before building either.** Add stage-duration logging (STT / upload / post-processing /
   insertion) — the July investigation asked for the same thing and could not close its accounting
   without it. One instrumented cloud dictation would say what upload actually costs; right now the
   0.4 s and the 10 s cases are indistinguishable from the outside.
4. **Keep it opt-in-shaped.** `cloudSTTProvider` allows arbitrary OpenAI-compatible endpoints
   (`AppSettings.swift:13-16`), and the accepted-format list is OpenAI's, not a standard. A codec
   change should be provider-gated or fall back to WAV on a 4xx that names the format.
5. **Change only the cloud call site.** `WAVEncoder` is shared with recovery staging
   (`RecoveryCaptureService.swift:111`, `:565`) and the debug artifact
   (`AppCoordinator.swift:4947`); both are read back by `AVAudioFile` and by `RecoveryItem`'s
   `.wav` liveness check. It must not be replaced in place.

### Unrelated, found on the way

`writeLastCaptureDebugArtifact` (`AppCoordinator.swift:4943-4952`, called at `:2446`) encodes and
writes the full capture to `last-dictation.wav` **synchronously on the stop path, on every
dictation** — 2.94 MB for the reference case — before transcription begins. It is described in its
own doc comment as a debug artifact for a finished investigation. Whatever happens to the upload
format, this is serial hot-path I/O that no longer has a consumer.

## Sources

- [Apple: `kAudioFormatFLAC` / Core Audio format identifiers](https://developer.apple.com/documentation/coreaudiotypes/kaudioformatflac)
- [OpenAI: speech-to-text file formats and the 25 MB limit](https://developers.openai.com/api/docs/guides/speech-to-text)
- [Apple Developer Forums: reading and writing MP3/MP4 audio on macOS](https://developer.apple.com/forums/thread/787004)
