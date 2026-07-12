# Task 3 Report: Draggable and Restorable Recording HUD

## Status

Implemented and verified.

## Changes

- Added an internal `HUDController.makePanel(size:)` factory so panel policy is testable without exposing the controller's panel.
- Preserved the nonactivating, non-key, non-main, floating panel policy and all three collection behaviors.
- Restores the saved normalized HUD position only when the panel is first created; otherwise uses the legacy bottom-center default.
- Captures the current origin before content resize, then restores and clamps it against the current display.
- Re-clamps the HUD when screen parameters change and unregisters the notification observer on teardown.
- Added an AppKit drag surface behind the SwiftUI controls. It uses `performDrag(with:)` and persists the normalized final frame after the drag returns.
- Kept `isMovableByWindowBackground` disabled and preserved all existing HUD controls, callbacks, and public methods.

## TDD Evidence

RED command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'FloatingPanelPolicyTests|FloatingPanelGeometryTests'
```

Result: exit 1. The new tests failed to compile because `HUDController.makePanel` and the initial resize-policy entry point did not exist, proving the requested policy was absent. During GREEN, the resize test was simplified to exercise the existing `FloatingPanelGeometry.clampedOrigin` API directly, avoiding an unnecessary forwarding helper.

Focused GREEN command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'FloatingPanelPolicyTests|FloatingPanelGeometryTests|HUDWarningPresentation'
```

Result: exit 0; 15 tests in 3 suites passed.

Full verification command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Result: exit 0; 329 tests in 31 suites passed.

Additional check: `git diff --check` exited 0.

## Self-review

- Scope is limited to the requested HUD source and two test files.
- The background drag view remains behind controls, so existing button and pill event handling retains priority.
- Persistence occurs once after `performDrag(with:)` returns; resize and display changes clamp without overwriting the user's saved display identity.
- Existing unrelated modifications to Task 1 and Task 2 reports were preserved.

## Concerns

No known functional concerns. AppKit drag routing is covered structurally by keeping global background movement disabled and placing the drag surface behind SwiftUI controls; automated tests cover policy and resize geometry, not synthesized mouse dragging.

## Important Review Fix: Pre-resize Display Capture

The resize path now captures both the panel origin and the current screen's visible frame before replacing the content view or calling `setContentSize`. The resized frame is restored and clamped against that captured display, so an AppKit screen reassignment caused by the new size cannot move the HUD to an adjacent display.

An internal pure `HUDController.resizedOrigin` seam makes this policy directly testable. The boundary regression supplies the original display and an adjacent post-resize display, proves the adjacent display would move the origin, and verifies the captured display preserves the pre-resize origin.

RED command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FloatingPanelPolicyTests.resizeClampsAgainstTheScreenCapturedBeforeTheWindowChangesScreens
```

Result: exit 1 with the expected compile failure, `type 'HUDController' has no member 'resizedOrigin'`.

GREEN regression command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FloatingPanelPolicyTests.resizeClampsAgainstTheScreenCapturedBeforeTheWindowChangesScreens
```

Result: exit 0; 1 test in 1 suite passed.

Fresh covering verification:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'FloatingPanelPolicyTests|FloatingPanelGeometryTests|HUDWarningPresentation'
```

Result: exit 0; 16 tests in 3 suites passed. `git diff --check` also exited 0.
