# Settings Refactor Design

## Goal

Bring the macOS settings window closer to the supplied Raycast reference while preserving every existing setting, binding, action, and editor workflow.

## Chosen approach

Replace the top-level tab strip with a compact, icon-led sidebar containing General, Templates, and Snippets. The selected section appears in a scrollable detail pane. General settings are organized into rounded cards with clear row labels, descriptions, dividers, and trailing controls.

Templates and Snippets retain their existing list/editor behavior; only their outer surface and spacing are updated for consistency.

## Contextual help

Settings that introduce a concept, trade-off, or prerequisite that is not self-evident receive a subtle trailing `questionmark.circle` control. Activating it opens a short native popover explaining the setting in context; hovering exposes the same summary as a tooltip. The control has an explicit accessibility label and does not displace the setting's primary action.

Help appears selectively for settings such as on-device context, automatic template selection, push-to-talk and hands-free modes, floating controls, recovery retention, local/cloud transcription choices, and app rules. Straightforward settings such as a microphone selector do not receive redundant help affordances.

## Visual language

- Native SwiftUI dark-aware surfaces; do not force a global appearance.
- SF Symbols for navigation and supporting icons, avoiding custom raster assets.
- Grouped rounded panels, comfortable spacing, and secondary helper text.
- System controls and accessibility labels remain intact.
- Contextual help uses native popovers and tooltips instead of a separate documentation surface.

## Boundaries

The refactor does not change persisted setting keys, recording/transcription behavior, hotkey handling, network actions, template logic, or snippet editing. It also does not add new settings categories or generated image assets.

## Verification

- Build the release package with `make build`.
- Run the available test suite with `make test` where the local Xcode environment supports it.
- Inspect the resulting settings layout manually for navigation, scrolling, controls, and template/snippet editors.
