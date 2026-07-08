# 0001 — Local-first Whisper over native SpeechAnalyzer

Status: accepted (2026-07-07)

## Context

macOS 26 ships `SpeechAnalyzer`/`SpeechTranscriber`: on-device, free, EN+PT, zero model management — the obvious "native platform" choice. The alternative is bundling Whisper (via WhisperKit) with an optional cloud STT engine.

## Decision

Transcription Engine is local Whisper (WhisperKit, `large-v3-turbo`) as primary, with an optional BYOK cloud engine behind the same interface. Native SpeechAnalyzer is not used.

## Consequences

- Best-in-class open-model accuracy for Brazilian Portuguese, which native Apple ASR does not match on messy/technical speech.
- Engine abstraction (local + cloud behind one interface) exists from day one; adding SpeechAnalyzer later as a third engine stays cheap.
- Costs: ~1.5 GB model download on first run, higher memory/battery than native ASR, WhisperKit becomes a load-bearing third-party dependency.
