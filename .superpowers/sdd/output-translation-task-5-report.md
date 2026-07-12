# Output Translation Task 5 Report

## Outcome

- Added reusable `TranslationControls` with explicit `Speak:` and `Output:` labels.
- The output menu uses the canonical nine-language `OutputLanguage.allCases` order, including German.
- Launcher and recording HUD consume the same `TranslationControlsState` effective/override/availability model.
- Launcher output choices update the pre-recording reducer selection; HUD choices update the active recording selection. Spoken choices remain isolated to the existing persistent pin and one-shot callbacks.
- Named translation choices remain visible but disabled when canonical Cloud availability is ineligible. `Same as spoken` stays enabled, and unavailable tooltip/accessibility help use the same canonical reason on a non-disabled wrapper.
- Launcher updates observe coordinator and Settings changes, keeping effective output and override presentation synchronized across surfaces.
- Existing nonactivating-panel, full-screen-space, first-click, and hover-grace policies were preserved. No translation processing path was wired.

## TDD evidence

RED:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'FloatingControlsPresentationTests|HUDWarningPresentationTests'
```

The focused target failed to compile because `TranslationControlsState`, the reusable presentation/control API, output callbacks, and HUD/launcher output state did not exist.

GREEN:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'FloatingControlsPresentationTests|HUDWarningPresentationTests'
```

Passed 16 tests across 2 suites.

Regression gate:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'FloatingControlsPresentationTests|HUDWarningPresentationTests|FloatingPanelPolicyTests|FloatingControlsSettingsTests|OutputLanguageSettingsTests|RecordingOutputSelectionTests'
```

Passed 43 tests across 6 suites.

Full suite:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Exited 0.

## Self-review

- Output callbacks mutate only `RecordingOutputSelection`; spoken callbacks remain unchanged.
- Availability derives from `AppSettings.cloudLLMSnapshot` through `CloudFeatureAvailability.make`, with no parallel eligibility rules.
- The launcher routes menu output events through its controller before re-rendering and observes HUD/coordinator output changes.
- The reusable control is the sole owner of the two menu presentations, avoiding launcher/HUD drift.
- `git diff --check` is clean. Pre-existing edits to unrelated task reports remain unstaged and uncommitted.
