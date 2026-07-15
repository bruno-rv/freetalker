# Launcher Placement Precedence Design

Date: 2026-07-15
Status: Approved 2026-07-15

## Objective

Make changes to the floating launcher's screen edge and along-edge position
take effect immediately, even after the user has manually dragged the launcher.

## Background

FreeTalker stores two placement representations:

- A selected screen edge and normalized along-edge position.
- A normalized free position written after manual dragging.

The free position currently remains authoritative after the user changes the
screen edge. Selecting **Bottom** therefore persists correctly but restores the
older right-side coordinates. Geometry for each edge is already correct; the
bug is conflicting sources of truth and missing invalidation.

## Placement rule

The user's most recent explicit placement action wins:

- Changing **Screen edge** replaces any saved free position.
- Changing the along-edge slider replaces any saved free position.
- Dragging the launcher creates a new saved free position.

This rule preserves both precise dragging and deterministic settings controls
without adding a new placement mode.

## Data flow

When `edgeLauncherEdge` changes, settings persist the new edge and clear
`launcherPanelPosition`. When `edgeLauncherPosition` changes, settings persist
the normalized along-edge value and clear `launcherPanelPosition`.

The controller already observes saved-position changes. Clearing the override
causes the next render to use the selected edge and along-edge value. After the
controller places the launcher, it stores the resulting normalized free
position. Later dragging overwrites that stored position normally.

The settings layer does not calculate screen coordinates. Display selection,
visible-frame clamping, and AppKit coordinate conversion remain in the existing
floating-controls geometry and controller layers.

## Scope

This fix does not add an **Edge** versus **Free** mode, change drag behavior, or
alter the geometry formulas. It only defines precedence and invalidates stale
saved coordinates.

Existing saved positions remain valid until the user changes an edge placement
control. No launch-time migration is required.

## Error handling

Settings persistence keeps the new edge and the cleared override in the same
synchronous preference update path. If stored position data is absent or
malformed, the controller falls back to the selected edge, matching the new
precedence rule.

## Verification

Add transition tests that:

- Seed a right-edge saved position, select **Bottom**, and verify the saved
  override is cleared and the final frame touches the display's bottom edge.
- Repeat the transition for **Top**, **Left**, and **Right**.
- Seed a free position, change the along-edge slider, and verify the slider
  takes effect.
- Drag after changing Settings and verify the dragged position becomes the new
  saved override.
- Relaunch and verify the most recent position survives.

Run the existing floating-controls settings and geometry suites. Perform a
multi-display smoke check with different visible frames and menu-bar or Dock
insets.

## Success criteria

Selecting **Bottom** moves the launcher to the bottom immediately regardless of
its prior saved position. The same rule holds for every edge and the along-edge
slider, while manual dragging and relaunch persistence continue to work.
