# Media plan Task 1 report: local diarization primitives

## Status

DONE

## Changes

- Added FluidAudio with the planned SwiftPM lower bound of 0.12.4 and linked its
  product to the FreeTalker executable target.
- Added pure `Sendable` transcript, speaker-turn, attributed-segment, and export-format types.
- Added a framework-independent timeline joiner that clips speaker turns to each
  transcript segment, rejects genuinely concurrent distinct speakers as ambiguous,
  and otherwise selects the unique greatest aggregate speaker duration. Per-speaker
  interval unions prevent overlapping turns from being double-counted.
- Added export-time speaker-name resolution for plain text, Markdown, SRT, and WebVTT.
- Added format-specific escaping and valid, monotonic subtitle cue normalization.
- Covered empty transcripts, missing/invalid speakers, zero/reversed durations, and
  overlapping transcript cues.

## TDD evidence

### RED

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TimelineAndExportTests
```

Exited 1 with expected missing `TimelineJoiner`, `TranscriptExporter`,
`TranscriptSegment`, `SpeakerTurn`, and `AttributedTranscriptSegment` symbols.

### GREEN

The same focused command exited 0; 8 tests passed in `TimelineAndExportTests`.

### Full verification

```text
swift package resolve
make test
make app
git diff --check
```

All commands exited 0. The final `make test` passed 188 tests in 18 suites. `make app`
completed the release build, bundle assembly, and ad-hoc signing. `git diff --check`
produced no output.

## Review hardening

- Added sequential equal/unequal speaker-transition tests and concurrent equal/unequal
  speech tests. Sequential attribution uses the unique greatest union duration; exact
  ties and any positive-duration concurrency across distinct speakers remain ambiguous.
- Speaker union durations are ranked as saturated integer milliseconds, matching the
  pipeline/export timestamp resolution. Mathematically equal fragmented and contiguous
  durations now tie deterministically; a one-millisecond advantage remains decisive.
- Added strict join validation for transcript and speaker intervals: both endpoints
  must be finite, start must be nonnegative, and end must be greater than start.
  Invalid transcript segments remain in the result but are unattributed. Export cue
  normalization remains deliberately separate.
- Expanded Markdown escaping for speaker labels and transcript text to cover the full
  CommonMark ASCII punctuation set, with safe HTML entity handling for ampersands and
  angle brackets.
- Documented and enforced a 99:59:59.999 subtitle ceiling before millisecond integer
  conversion. Huge finite timestamps saturate without trapping and near-ceiling cues
  remain valid and monotonic.
- Review-focused RED cycles recorded the expected ambiguity/escaping failures and the
  prior fatal huge-timestamp conversion trap. The final focused GREEN passed 19 tests
  in `TimelineAndExportTests`.

## Dependency note

The planned `.package(..., from: "0.12.4")` constraint resolved to FluidAudio
0.15.5. SwiftPM emits an upstream warning for an unhandled `benchmark.md` file in
FluidAudio; it does not affect resolution, compilation, tests, or the release build.

## Scope review

- Timeline and export logic import only Foundation and do not reference FluidAudio APIs.
- Speaker names are not copied into attributed segments; mappings are applied only
  when exporting, so renames propagate without recomputing the timeline join.
- The two pre-existing deleted legacy report files remain untouched and are excluded
  from this task's commit.
