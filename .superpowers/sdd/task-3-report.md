# Voice editing plan task 3 report: local preview coordinator

## Status

DONE

## Changes

- Added a local-only Foundation Models edit service that creates a fresh language-model session
  for every edit and frames selected text/instructions as escaped, untrusted data.
- Added a memory-only coordinator that resolves exact normalized snippet matches before local
  generation, exposes ambiguous matches for explicit choice, and never writes during preview.
- Confirmation delegates replacement exclusively to `SelectionAccessing`, preserving its immediate
  bracketed revalidation; failed stale confirmations retain the preview and perform no successful
  write.
- Cancel, successful confirmation, and explicit copy clear the held instruction and preview.
  Clipboard writes occur only through the explicit copy action.
- Added a SwiftUI preview/chooser with explicit Replace, Copy, and Cancel actions.
- Added focused coverage for missing selections, snippet priority, ambiguity, preview-only behavior,
  cancel, stale and successful confirmation, explicit copy, and local-generation failure.

## TDD evidence

### RED

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VoiceEditCoordinatorTests
```

Exited 1 with the expected missing `VoiceEditCoordinator` and `LocalEditServicing` symbols.

### GREEN

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter VoiceEditCoordinatorTests
```

Exited 0; 8 focused tests passed.

## Verification

```text
make test
make app
git diff --check
```

The final full suite passed with 158 tests in 16 suites. The release executable and ad-hoc signed app
bundle built successfully. Diff whitespace validation passed.

## Concerns

- Task 4 still owns app lifecycle, hotkey-to-presentation wiring, and the snippet settings UI. This
  task accepts the existing `pendingVoiceEditSelection` snapshot through the coordinator initializer
  so that integration does not recapture or weaken the Task 1 trust boundary.

## Review follow-up

- Added operation-generation invalidation checks after both snippet lookup and local generation.
  Cancel now clears state immediately, and suspended work cannot publish a late preview, chooser,
  or error.
- Made the sensitive selection snapshot nullable and observable through a privacy-state flag. Every
  terminal path clears the snapshot and instruction; the preview no longer duplicates original text.
- Made clipboard writes fallible and switched the system implementation to `writeObjects` without a
  preemptive clear. Copy failures preserve the preview for retry and expose an actionable message;
  the preview view dismisses only after a successful copy.
- Mapped every `SelectionAccessError` to a specific accessible message while retaining the preview
  for retry or explicit copy. The stale-confirm fake now throws before recording any mutation.

### Review TDD evidence

The focused RED build failed on the missing sensitive-state, fallible-copy, invalidation, and typed
confirmation-error contracts. The focused GREEN run passed 11 tests, including five parameterized
selection-error cases.

## Second review follow-up

- The coordinator now owns the actual generation `Task`, cancels it on cancel, restart, every
  terminal cleanup, and propagation from a cancelled `begin()` caller. Publication tokens remain as
  a second guard, but cancellation now reaches the suspended edit service and Foundation Models
  request. `LocalEditService` checks cancellation immediately before and after `session.respond`.
- Generation no longer carries a full `SelectionSnapshot` across snippet lookup; it extracts only
  the selected string at the point local generation needs it.
- The default pasteboard path snapshots every data-backed type, attempts `writeObjects`, and restores
  the prior supported items when that write fails or throws.
- Added a cancellation-aware suspended-service regression that exits through `CancellationError`
  without manual resumption, plus an injectable failed-pasteboard restoration regression.

### Second review TDD evidence

The focused RED build failed on the missing pasteboard adapter/item/copy types. The focused GREEN
run passed 12 tests, including the owned-task cancellation observation and clipboard restoration.
