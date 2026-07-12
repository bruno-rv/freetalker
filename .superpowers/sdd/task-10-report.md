# Task 10 report: Scratchpad AI controls

## Outcome

Implemented AI transformations in the scratchpad with always-visible Improve,
Expand, Condense, and Custom instruction controls. Actions transform the UTF-16
selection when present and otherwise the full document. Each click captures one
cloud settings snapshot and reuses it for availability and the request.

Replacement is accepted only while the document revision, range, and source text
still match. Accepted output retains the source's inline attributes and surrounding
paragraph style and is registered as one undoable edit. Cancellation, failures,
empty output, invalid custom instructions, and source drift leave the document
unchanged; actionable failures are presented without replacing the editor status.

Disabled controls remain visible. Their disabled reason is installed on a
non-disabled AppKit wrapper as a tooltip and duplicated as accessibility help.
Only one transformation can be in flight and a spinner presents that state.
Availability also refreshes after every text-storage edit, so controls disabled for
an empty document become usable as soon as text is entered. This uses the storage's
editing notification and leaves `ScratchpadDocument`'s rich-text delegate intact;
the observer is removed when the window controller is released.

Each AI request also has a monotonically increasing generation. Only the active
generation may apply output, present an error, or clear progress. Closing the
window invalidates the generation, cancels the task, and clears progress
immediately, so a cancellation-ignoring backend cannot affect a reopened window
or a newer request.

Cloud provider, base URL, and model availability stays current through the
existing `AppSettings` publishers. Successful API-key saves emit a notification
that carries no key material, allowing an open scratchpad to refresh the same
canonical eligibility and disabled-reason presentation.
If one of those settings changes during a request, the controller records a
pending refresh without taking another request snapshot. Matching request
finalization then reads the latest canonical snapshot once and renders it, so
the completed request cannot restore stale availability.

## TDD evidence

- RED: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScratchpadAIActionTests`
  exited 1 because the Task 10 snapshot/apply APIs, AI controls/state, action methods,
  and injectable transformation dependencies were absent.
- Follow-up RED: deterministic cancellation-ignoring request tests and live
  configuration tests failed before generation gating and settings observation
  existed; the exact action-label test also exposed the abbreviated Improve label.
- Follow-up RED: an in-flight configuration-change test showed finalization
  reused the request's stale settings and discarded the refresh event.
- Final RED: whitespace-only source drift left non-custom actions enabled after
  rejection and allowed a second whitespace request because finalization used a
  raw non-empty check.
- Final click-path RED: the rejected second whitespace click made controls
  appear enabled again because its presentation branch still passed
  `hasInput: true` instead of the shared trimmed predicate.
- GREEN: the focused command passed 26 tests after the implementation and review
  follow-ups.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ScratchpadAIActionTests|ScratchpadEditorTests|ScratchpadPersistenceTests'`
  plus `FloatingControlsSettingsTests` passed 54 tests in 4 suites.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  exited 0 with the complete package suite passing.
- `git diff --check` passed.

## Self-review

- Confirmed all modifications are limited to the three assigned scratchpad source
  files, `ScratchpadAIActionTests.swift`, and this report.
- Confirmed the existing document insertion-token revision is the authoritative
  edit-drift gate; the public snapshot exposes that same real document revision,
  along with the required range and original text.
- `ScratchpadDocument.swift` was added to the amendment scope solely to expose its
  existing revision as read-only within the module. This removes the misleading,
  collision-prone `String.hashValue` snapshot without duplicating revision state.
- Confirmed no dependency, persistence schema, or unrelated formatting changes
  were introduced.

## Concerns

None known.
