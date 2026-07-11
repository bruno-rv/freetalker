# File import and speaker separation design

## Supported input

Library gains an **Imports** segment with file picker and drag-and-drop support for
WAV, M4A, MP3, MP4, and MOV. A security-scoped bookmark preserves access across
launches. FreeTalker never modifies or deletes the source file.

AVFoundation decodes audio and extracts video audio into a disk-backed 16 kHz mono
working stream inside the job directory. Jobs show decoding, transcribing,
diarizing, and finalizing progress independently.

## Local pipeline

WhisperKit produces timestamped multilingual transcript segments with the selected
downloaded model. Add FluidAudio as the sole new package dependency and use its
offline Core ML diarizer for speaker time ranges. Diarization models download on
demand with visible progress and use a FreeTalker-managed local cache.

A deterministic timeline join assigns each transcript segment to the speaker with
the greatest temporal overlap. Ties or overlapping speech are marked ambiguous
rather than guessed. Diarization failure preserves the transcript with an Unknown
speaker and a separate Retry speaker separation action.

## Speaker names

Detected speakers begin as Speaker 1, Speaker 2, and so on. Users can rename them.
Names are stored per import, immediately update every rendered segment, and propagate
to subsequent plain-text, Markdown, SRT, and VTT exports.

## Job behavior

Cancel preserves a resumable job and source bookmark. Delete removes the derived
working audio, transcript, segments, and bookmark, but never the source. Interrupted
jobs return to queued on launch. Long files use FluidAudio's disk-backed offline path
and never require loading the complete file into memory.

## Acceptance criteria

- Every supported format imports locally from picker and drag-and-drop.
- Video audio is extracted without retaining a duplicate video.
- Imported transcription uses the selected multilingual Whisper model.
- Diarization failure does not destroy a successful transcript.
- Speaker renames update the full transcript and all four export formats.
- Delete never touches the source file.
- No imported audio, transcript, or speaker data leaves the Mac.

