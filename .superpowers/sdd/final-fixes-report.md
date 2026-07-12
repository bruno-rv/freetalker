# Final review fix wave

## Scope

- I1: surface `ScratchpadDocument.warning` through the window's canonical status presentation.
- I2: clear supported inline and list/paragraph formatting at an empty selection/caret.
- Narrow recommendation: exercise `ScratchpadWindowController` registration through the real `AppCoordinator` recording destination lifecycle without microphone or network access.

## RED evidence

After adding production-window/editor regressions, the targeted run failed for the expected missing behavior:

- `corruptDocumentWarningIsVisibleOnFirstOpenWithoutOverwritingSource`: status was `nil`.
- `debouncedSaveFailureAppearsWhileOpenAndSuccessfulRetryClearsIt`: the save warning was not presented and its later emission was stale.
- `clearFormattingAtCaretClearsHeadingAndTypingAttributesForCurrentParagraph`: the heading font remained.
- `clearFormattingAtCaretRemovesListStructureButPreservesUnrelatedParagraphProperties`: `textLists`, list indents, and the list tab remained.
- `caretClearFormattingIsOneUndoAndOnePersistenceSchedule`: no document edit or persistence schedule occurred.
- The empty-document typing-attribute regression passed immediately, confirming existing safe behavior for that edge case.

The first save-failure test compile exposed that no production injection seam existed. A narrow save-operation parameter was added to `ScratchpadDocument` and forwarded by `ScratchpadWindowController`; rerunning then produced behavioral RED failures rather than a compile error.

## GREEN implementation

### Persistence warning presentation

- `ScratchpadWindowController` subscribes weakly to `scratchpadDocument.$warning` on the main run loop.
- The cancellable is explicitly cancelled from `deinit`; the sink does not retain the controller.
- Canonical status ordering is retained close warnings, current document warning (deduplicated), then recovery guidance.
- The main-run-loop hop is required because `@Published` emits before assignment; it ensures status recomposition reads the new warning value.
- A successful retry clears `ScratchpadDocument.warning`, which recomposes and clears the visible status when no retained warning/recovery remains.
- Corrupt input remains untouched on open/flush until a genuine text edit marks the document dirty.

### Caret clear formatting

- Typing attributes are cleared first, retaining unsupported attributes such as links.
- For a non-empty document, the current UTF-16 paragraph is changed in one `perform` edit/undo group.
- Supported inline formatting attributes are removed across that paragraph.
- Semantic lists are removed, and only the list-specific `18/36` indents and `18` tab are reset.
- Unrelated paragraph properties (alignment, spacing, and unrelated tabs) are preserved.
- Empty documents return safely after clearing typing attributes and never form an invalid text range.

### Production wiring recommendation

- Added a production-wiring test using the real window controller router registration and real `AppCoordinator` lifecycle completion/recovery APIs.
- Capture start alone is replaced with a closure, so the test requires neither microphone permission/audio nor network processing.
- The test verifies accepted insertion, token invalidation, visible recovery, coordinator persistence, and cleanup of shared coordinator state.

## Verification

- New regressions together: 7 tests in 2 suites passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter 'ScratchpadRecordingTests|ScratchpadPersistenceTests|ScratchpadEditorTests'`: command exited 0. Editor suite (16 tests) and persistence suite (9 tests) reported passing; the captured Swift Testing stream stopped at `closeDuringCaptureStopsThenCompletionBecomesPendingAndReopensIdle` before printing the recording-suite/final summary. No test helper remained. This output behavior was repeatable with the combined filter; the new recording tests pass individually.
- `make test`: exited 0. The full run reported broad passing coverage, but the captured Swift Testing stream ended during the serialized recording suite before the final summary even after waiting for the helper to exit.
- `make app`: release build, bundle assembly, and ad-hoc codesign succeeded.
- `git diff --check`: passed.

## Self-review

- No unrelated production files or existing task reports were edited.
- Removed the now-redundant stored persistence value after introducing the save-operation seam.
- The coordinator integration test clears both its pending recovery and weak router registration.
- Remaining concern: SwiftPM/Swift Testing's combined output does not provide a final summary for the requested focused invocation even though it exits 0; individual regression evidence is therefore the strongest evidence for the newly changed behavior.
