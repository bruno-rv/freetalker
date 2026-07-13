# Settings Refactor Design

## Goal

Bring the macOS settings window closer to the supplied Raycast reference while preserving every existing setting, binding, action, and editor workflow.

## Chosen approach

Replace the top-level tab strip with a compact, icon-led sidebar containing General, Templates, and Snippets. The selected section appears in a scrollable detail pane. General settings are organized into rounded cards with clear row labels, descriptions, dividers, and trailing controls.

Templates and Snippets retain their existing list/editor behavior; only their outer surface and spacing are updated for consistency.

## Visual language

- Native SwiftUI dark-aware surfaces; do not force a global appearance.
- SF Symbols for navigation and supporting icons, avoiding custom raster assets.
- Grouped rounded panels, comfortable spacing, and secondary helper text.
- System controls and accessibility labels remain intact.

## Boundaries

The refactor does not change persisted setting keys, recording/transcription behavior, hotkey handling, network actions, template logic, or snippet editing. It also does not add new settings categories or generated image assets.

## Verification

- Build the release package with `make build`.
- Run the available test suite with `make test` where the local Xcode environment supports it.
- Inspect the resulting settings layout manually for navigation, scrolling, controls, and template/snippet editors.
