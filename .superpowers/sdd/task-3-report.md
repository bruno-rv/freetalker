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
- Task 4 still owns lifecycle wiring of the engine event receiver and selection-triggered reload calls.

## Findings follow-up

### RED

The follow-up began by referencing the required production reload seam and active/install event from SelfCheck. `make selfcheck` failed before implementation with:

- `cannot find 'ModelReloadController' in scope`
- `type 'SpeechModelEngineEvent' has no member 'active'`

### GREEN

- `ModelReloadController` is now the production seam used by both initial engine load and `reload(to:)`; offline fakes exercise the same guarded install, serialization, failure, revert, event, and convergence code as production.
- The controller keeps the prior kit on candidate failure, conditionally reverts only the still-current failed setting, and continues to a newer third selection.
- Target state remains nondeletable from `.busy`, through `.downloading`, until terminal `.active` or `.failed`; `.downloaded` is no longer emitted before candidate construction.
- `.active` is emitted immediately after guarded install/swap. `SpeechModelStore` atomically clears the prior active flag, activates the installed variant, and marks it downloaded.
- Ready status is published only by the post-install callback, after guarded state contains the installed kit and variant.
- Offline checks cover initial busy→active ordering, failure preservation/revert, third-selection non-clobber and convergence, absence of premature downloaded events, captured old-kit identity, active store alignment, and maximum one concurrent candidate load.

Fresh final verification: `make selfcheck` passed and `git diff --check` passed.

## Delayed-progress and initial-failure follow-up

### RED

SelfCheck first referenced the production progress-attempt guard before implementation. `make selfcheck` failed with `cannot find 'ModelLoadProgressGuard' in scope`.

### GREEN

- Every controller failure now reaches the engine's terminal event path, which publishes `Failed to load <catalog display name>: <hint>` for preload, lazy load, initial transcription load, and reload alike.
- `preload()` no longer overwrites that specific failure with a generic status.
- Each engine download receives a unique attempt identity. Progress delivery and terminal invalidation are ordered on `MainActor`; active/failure invalidates the attempt before publishing terminal store/status state, so callbacks scheduled later are ignored.
- Async offline checks deliberately hold progress callbacks until after terminal active/Ready and failure states, then release them and verify neither state regresses.

Fresh final verification: `make selfcheck` passed without warnings and `git diff --check` passed.
