# Local workflows shared design

## Purpose

Provide one durable, local-only foundation for recovery, context-aware styles,
voice editing and snippets, and imported-media transcription. Each feature owns
its UI and service boundary; `AppCoordinator` orchestrates them without absorbing
their persistence or processing logic.

## Architecture

`TranscriptionJobStore` persists long-running work in SQLite. A job records its
kind (`recovery` or `mediaImport`), source reference, state, progress, timestamps,
language, speech model, template, failure classification, and terminal result.
`JobAttempt` records retries without overwriting earlier failure evidence.

The shared state machine is:

`queued -> processing -> ready | failed | cancelled`

On launch, a job left in `processing` becomes `queued`, preserving its source and
attempt history. One actor-backed `LocalJobRunner` executes jobs serially so model
downloads, transcription, and diarization cannot race. Cancellation is cooperative
between pipeline stages; it never deletes the source automatically.

## Persistence

SQLite gains versioned migrations for:

- `transcription_jobs`
- `job_attempts`
- `speaker_segments`
- `speaker_names`
- `snippets`

Recovery files live under
`~/Library/Application Support/FreeTalker/recoveries/`. Imported files remain
user-owned. FreeTalker stores a security-scoped bookmark and job-derived metadata;
it never deletes the original import.

## Privacy contract

All four workflows are local-only. Context text, OCR output, screenshots, selected
text, edit instructions, and edit previews are memory-only. They are never written
to SQLite, history, logs, recovery files, analytics, or cloud/BYOK requests.

README and Settings must display this disclaimer:

> Context, edits, snippets, imported media, and speaker separation are processed
> locally on this Mac. Screen context and edit previews stay in memory and are
> never sent to cloud or BYOK providers.

## Settings

UserDefaults persists:

- recovery retention: 1, 7, 30, 90 days, or never; default 7 days
- context scope: off, selected text, focused field, active window, or window OCR;
  default off
- automatic style: on or off; default off
- voice-edit hotkey

## Testing

Restore `Tests/FreeTalkerTests` and retain tests whenever their production behavior
exists. Tests use temporary SQLite databases and directories, deterministic clocks,
and fake transcription, diarization, context, OCR, and insertion services. Tests
must not download models, use the network, inspect the real screen, modify the real
pasteboard, or access user files.

## Error handling

Errors are typed by stage. Source access, decoding, transcription, diarization,
context capture, local generation, persistence, and insertion remain distinguishable.
Partial success is preserved: a transcript remains usable when diarization or local
post-processing fails.

## Explicit non-goals

- Cross-device synchronization
- Cloud context, editing, or diarization
- General workflow-engine infrastructure
- Live meeting capture
- Autonomous edits without confirmation

