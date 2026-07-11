# Task 3 report — WhisperKitEngine atomic model reload

## RED

`make selfcheck` failed after the engine-focused checks were added, before production support existed. Relevant compiler failures:

- `type 'WhisperKitEngine' has no member 'shouldReload'`
- `cannot find 'GuardedKitState' in scope`

The first probe implementation also exposed Swift 6 actor-isolation errors in the test helper; that helper was corrected before using it as GREEN evidence.

## GREEN

- Added one lock-guarded state containing kit identity and loaded variant; `isLoaded` is derived from the guarded kit.
- Transcription captures the guarded kit once and retains that identity across swaps.
- Engine downloads use the shared `SpeechModelDownloadCoordinator`.
- Initial load and reload publish busy/download/downloaded/failure events and model-specific status.
- Reloads serialize independently from transcription, preserve the old kit on failure, conditionally revert only the still-current failed selection, and converge to the latest setting.
- Audited `isLoaded` callers: `AppCoordinator` live-preview gating and the Settings cloud hint both ask whether any local kit is loaded, so no Task 3 adjustment is needed. Task 4 still needs to wire the store receiver and selection-triggered reload lifecycle.

Verification evidence is recorded in the commit/handoff command output: `make selfcheck` and `git diff --check`.

## Self-review

- Scope is limited to `WhisperKitEngine.swift`, `SelfCheck.swift`, and this required report.
- No direct `WhisperKit.download` remains in the engine.
- No production network/model download is exercised by SelfCheck.
- The existing event interface lacks a distinct `active` event; successful swaps instead publish model-specific Ready status, while Task 4's lifecycle wiring can update store active identity from settings/reload completion.
