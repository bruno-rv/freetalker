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

## Follow-up privacy and recovery review

RED evidence:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingDestinationTests
```

Compilation failed on the absent production snapshot gate and pending-recovery
APIs. A second focused RED failed on the absent
`deliverScratchpadCompletion(_:for:)` production delivery path.

The real pill-click and panel-finish handlers now gate their stop-time
`NSWorkspace`, insertion-target, and context-target reads by destination.
External dictation still captures all three synchronously before the click is
processed; scratchpad dictation performs zero such reads on every stop path.

Rejected completion or a missing weak router stores refined text in a
token-keyed in-memory recovery slot. Task 8 can query or consume it without
pasteboard insertion or Library recording. Successful delivery and explicit
consumption clear it; cancellation clears the matching token. The HUD reports
“Dictation ready — reopen Scratchpad to recover it” rather than hiding as if
delivery succeeded.

Fresh GREEN evidence:

- `RecordingDestinationTests|RecordingStateMachine`: 10 destination tests
  passed (the repository has no separately named RecordingStateMachine suite).
- `AutomaticStyle|ContextRouting`: 26 tests passed.
- Full `swift test`: 348 tests across 33 suites passed.

## Production lifecycle harness follow-up

Replaced test-shaped destination state helpers with
`RecordingDestinationLifecycle`, the stateful object owned by the real
`AppCoordinator`. The production capture-start path calls `begin`, the real
cancel path calls `cancel`, and both external insertion/Library completion and
scratchpad async completion call `complete`. Tests drive those same methods
with injected capture, stop, external-side-effect, and router spies; they no
longer simulate reset or cancellation by calling leaf clear/take helpers.

RED: the focused destination suite failed to compile because
`RecordingDestinationLifecycle` and its start/cancel/completion APIs did not
exist. GREEN: destination suite 8/8, context/style regressions 26/26, full suite
346 tests across 33 suites.

## Async production orchestration follow-up

Added `RecordingDestinationLifecycle.runAsync`, now called by both the real
external `processDictation` wrapper and the real scratchpad processing Task.
The seam accepts only the existing processing operation, refined-text
projection, and external side-effect closure, so transcription/refinement is
not duplicated. It routes async success, thrown failure, and cancellation by
destination.

RED: focused async lifecycle tests failed to compile because `runAsync` was
absent. GREEN: destination suite 11/11, context/style 26/26, full suite 349
tests across 33 suites. Async spies prove external completion performs both
insertion and record effects, scratchpad rejection/weak loss performs zero
external effects and retains recovery, transcription failure notifies the
router, and cancellation emits cancellation and clears recovery.
