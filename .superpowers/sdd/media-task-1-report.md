# Media plan Task 1 report: local diarization primitives

## Status

DONE

## Changes

- Added FluidAudio with the planned SwiftPM lower bound of 0.12.4 and linked its
  product to the FreeTalker executable target.
- Added pure `Sendable` transcript, speaker-turn, attributed-segment, and export-format types.
- Added a framework-independent timeline joiner that attributes a segment only when
  every positive overlap belongs to one distinct speaker. Cross-speaker overlap is
  explicitly ambiguous and remains unattributed.
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

All commands exited 0. The final `make test` passed 181 tests in 18 suites. `make app`
completed the release build, bundle assembly, and ad-hoc signing. `git diff --check`
produced no output.

## Review hardening

- Added equal- and unequal-duration cross-speaker overlap tests; both now remain
  unattributed instead of guessing a dominant speaker.
- Added strict join validation for transcript and speaker intervals: both endpoints
  must be finite, start must be nonnegative, and end must be greater than start.
  Invalid transcript segments remain in the result but are unattributed. Export cue
  normalization remains deliberately separate.
- Expanded Markdown escaping for speaker labels and transcript text to cover
  backslash, backtick, asterisk, underscore, braces, brackets, parentheses, heading,
  list, link, and emphasis punctuation, with HTML entity escaping for ampersands and
  angle brackets.
- Review-focused RED recorded five expected failures. The final focused GREEN passed
  12 tests in `TimelineAndExportTests`.

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
