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

## Review-finding follow-up

- Generalized the secret-free refresh signal to `cloudLLMCredentialsDidChange`; the old Scratchpad name is a compatibility alias only. The Settings credential writer posts it only after a successful save or delete and never attaches the secret as object/user-info payload.
- Launcher and coordinator/HUD now observe default output, provider, base URL, model, and credential changes. Credential refresh is synchronous after successful mutation; configuration refresh occurs on the next main-queue turn because `@Published` emits before storing the new value.
- Moved all launcher settings/output/credential subscriptions into `start()`. `stop()` cancels them, restart reinstalls one set, and repeated active `start()` calls remain idempotent.
- Disabled named output commands now sit inside a non-disabled accessibility element that owns the canonical language label, `Unavailable` value, canonical help/hint, and tooltip while the visual command stays disabled. Eligible choices retain their normal menu-button accessibility.

Follow-up RED reproduced missing general notification/writer, missing restart-safe subscription injection, missing coordinator presentation seam, and missing disabled-wrapper accessibility policy.

Follow-up focused gate:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'FloatingControlsPresentationTests|HUDWarningPresentationTests|FloatingPanelPolicyTests|OutputLanguageSettingsTests|ScratchpadAIActionTests.cloudConfigurationAndCredentialChangesRefreshAvailabilityWithoutReopen'
```

Passed 30 tests across 5 suites.

Fresh full-suite `swift test` exited 0. `git diff --check` remained clean, and panel nonactivation/full-screen/first-click/hover behavior was unchanged.
