# Full-screen Scratchpad fix report

## Outcome

Scratchpad now uses the same focusable utility-window policy as Settings. Its
normal `NSWindow` joins all Spaces and other applications while remaining a
normal-level, titled, resizable, key-capable window rather than adopting HUD
panel behavior.

## Changes

- Renamed `configureSettingsWindow` to
  `configureFocusableUtilityWindow` to reflect its shared purpose.
- Kept Settings behavior unchanged through the renamed policy.
- Applied the shared policy when `ScratchpadWindowController` constructs its
  window.
- Added a controller-level regression test covering cross-Space behavior and
  the absence of full-screen, stationary, floating, and nonactivating HUD
  characteristics.

## TDD evidence

- RED: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ScratchpadRecordingTests.windowJoinsOtherApplicationsFullScreenSpacesWithoutBecomingAHUD`
  exited 1 because the actual Scratchpad window lacked `.canJoinAllSpaces` and
  `.canJoinAllApplications`; the remaining normal-window assertions passed.
- GREEN: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'AppLifecycleWindowPolicyTests|ScratchpadRecordingTests'`
  exited 0 after applying the shared policy.

## Verification

- `make test` — exit 0.
- `make app` — exit 0; release app assembled and ad-hoc signed.
- `git diff --check` — run before commit; expected clean.

The build retains the pre-existing FluidAudio warning about its unhandled
`benchmark.md` file. No HUD flags, `orderFrontRegardless`, or new dependency
were introduced.
