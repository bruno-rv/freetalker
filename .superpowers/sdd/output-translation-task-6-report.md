# Task 6 report — translated recording delivery

## Outcome

- Added an immutable `RecordingProcessingContext` containing the captured
  destination, spoken-language hint, output language, resolved Template, and
  eligible cloud settings snapshot. STT receives only `en`, `pt`, or `nil`.
- Added `RecordingProcessingResult` so Library recording receives source
  language, requested output language, raw transcript, final output, Template,
  and engine metadata as one value rather than positional arguments.
- Kept Same-as-spoken on the existing preserve-source processor path.
- Routed named output directly through `TranslationService`/`Translating`
  exactly once. Named output never resolves or invokes the active processor,
  Apple Foundation Models, or a raw-source fallback.
- Translation failure throws `OutputTranslationFailure`, retaining the raw
  source and immutable processing context for Task 7. The coordinator defers
  that failure until Task 7 consumes it. No insertion or Library record occurs
  on that failure, and it is not treated as a transcription failure.
- Preserved the existing external insertion target and Scratchpad insertion
  token routes. Scratchpad completion still uses its captured selection token;
  external context/focus drift protection remains unchanged.
- Started output selection only after capture successfully starts and cleared
  it on stop, cancellation, microphone denial, and capture-start failure.

## TDD evidence

RED:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'OutputTranslationPipelineTests|RecordingDestinationTests|ScratchpadRecording'
```

Exited 1 with the expected missing-feature diagnostics:
`RecordingProcessingContext`, `RecordingProcessingResult`,
`OutputTranslationFailure`, and the named-output pipeline parameters did not
exist.

GREEN:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'OutputTranslationPipelineTests|RecordingDestinationTests|ScratchpadRecording'
```

Exited 0. The output translation pipeline suite, recording destination suite,
and Scratchpad recording suite passed.

Follow-up RED/GREEN cycles:

- RED exited 1 because `pipelineFailureKind` was absent; GREEN proves
  translation errors are distinct from transcription errors and do not enter
  failed-audio preservation.
- RED exited 1 because deferred translation failure APIs were absent; GREEN
  proves the coordinator retains source/context for Task 7 and consumes that
  state exactly once.
- A Scratchpad regression passes translated final text through the captured
  token after selection drift and verifies replacement at the original
  selection.

Regression verification:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'OutputTranslation|RecordingDestination|ScratchpadRecording|AutomaticStyle'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ContextRouting
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

All three commands exited 0. `ContextRouting` passed 9/9, and the full package
suite completed with no failures.

## Changed files

- `Sources/FreeTalker/AppCoordinator.swift`
- `Sources/FreeTalker/Core/RecordingDestination.swift`
- `Tests/FreeTalkerTests/OutputTranslationPipelineTests.swift`
- `Tests/FreeTalkerTests/RecordingDestinationTests.swift`
- `Tests/FreeTalkerTests/ScratchpadRecordingTests.swift`
- `.superpowers/sdd/output-translation-task-6-report.md`

The existing Scratchpad controller required no production change: translated
final text travels through its existing token-bound completion route, now
covered explicitly after selection drift.

## Residual risk / Task 7 handoff

- Task 7 still needs to present and resolve the coordinator's deferred
  `OutputTranslationFailure`; Task 6 deliberately does not insert source text
  or silently recover on named translation failure.
- The UI-level stop paths depend on AppKit/audio state and are not driven
  end-to-end in unit tests. Terminal clearing is covered by the
  `RecordingOutputSelection` reducer; coordinator call sites were reviewed,
  but tests do not simulate every physical stop trigger.

No commit was created.
