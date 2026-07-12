# Task 5 report — explicit recording destinations

## Outcome

- Added `ScratchpadInsertionToken`, `RecordingDestination`, and the main-actor
  `ScratchpadRecordingRouting` protocol.
- Added a weak scratchpad router and destination state to `AppCoordinator`.
- Added start-only `startHandsFreeRecording(destination:)` and
  `stopCurrentRecording()` entry points. Launcher starts enter locked hands-free
  mode immediately; active or processing launches return `false` and do not
  toggle the current recording.
- Kept hotkey capture explicitly external.
- Preserved the external stop-time app/AX/context snapshots and existing
  insertion and Library wrapper behavior.
- Extracted transcription/refinement into a private non-`Sendable` result.
  Scratchpad completion uses that stage without external app/context capture,
  App Rules, insertion, pasteboard, or Library recording.
- Routed scratchpad preview, completion, cancellation, and failures through the
  weak router. Scratchpad language resolution uses one-shot/default pin only.
- Routed microphone-authorization and capture-start failures to the scratchpad
  router without retaining destination state. Terminal paths atomically take
  and clear their destination.
- Added an injected destination-event seam proving external completion alone
  invokes insertion/Library effects and scratchpad events invoke only its
  router. A rejected scratchpad completion remains visibly recoverable instead
  of hiding the HUD as success.
- Wired the floating launcher dictation button to start `.external` recording.

## TDD evidence

RED command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingDestinationTests
```

The test target failed to compile because `ScratchpadInsertionToken`,
`RecordingDestination`, and `AppCoordinator.launcherStartDecision` did not
exist.

GREEN and regression commands:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'RecordingDestinationTests|RecordingStateMachine'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'AutomaticStyle|ContextRouting'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Results: destination tests passed 7/7; automatic-style/context-routing passed
26/26; full suite passed 345 tests across 33 suites.

## Self-review

- `recordingDestination` is installed only after capture starts and cleared on
  start failure, stop, and cancellation.
- Injected spies cover external completion side effects, scratchpad preview,
  success, cancellation, start/transcription failure routing, completion
  rejection, weak ownership, and state reset.
- Busy starts leave the active recording and its destination untouched.
- The launcher callback does not activate FreeTalker and its copy already says
  “Start dictation,” so no presentation-copy change was needed.
- No dependency or unrelated source change was introduced.
