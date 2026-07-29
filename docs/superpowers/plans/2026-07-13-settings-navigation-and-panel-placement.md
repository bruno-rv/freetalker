# Settings Navigation and Panel Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Divide General into focused settings destinations with generated circular image icons, and persist draggable launcher, recording HUD, and transient HUD positions inside the usable screen area.

**Architecture:** Add generated PNG files as SwiftPM resources and replace sidebar SF Symbol rendering with decorative images. Separate navigation destinations present existing settings sections without changing state ownership. Normalize and persist one display-aware position per floating surface; controllers restore and clamp positions using `NSScreen.visibleFrame`, which automatically respects a visible Dock and reaches the physical bottom when it auto-hides.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Swift Package Manager resources, XCTest.

## Global Constraints

- Keep all existing setting bindings, hotkeys, dialogs, cloud actions, templates, snippets, and accessibility text intact.
- Navigation images are original project PNGs, decorative only; destination titles remain accessible.
- Panels stay nonactivating and `isMovableByWindowBackground == false`.
- Positions must clamp to `NSScreen.visibleFrame`; never overlap a visible Dock or menu bar.
- Preserve existing edge/along-edge launcher settings as migration input only.
- Use a dedicated saved position for launcher, recording HUD, and transient HUD.

---

### Task 1: Add generated icon resources and resource loading

**Files:**
- Create: `Sources/FreeTalker/Resources/SettingsIcons/{privacy,recording,transcription,processing,launcher,storage,templates,snippets}.png`
- Modify: `Package.swift`
- Modify: `Sources/FreeTalker/UI/SettingsChrome.swift`
- Modify: app bundle staging path in `Makefile` if required by the existing `make app` layout.

**Interfaces:**
- Produces: `SettingsDestination.imageName: String` and a resource-backed sidebar icon view.
- Consumes: eight generated 128px PNG assets.

- [ ] Generate eight consistent circular icon assets with no text, crop/store them under the resource path, and inspect their dimensions.
- [ ] Add `.process("Resources")` to the FreeTalker executable target and copy the generated SwiftPM resource bundle beside the executable when building the app bundle.
- [ ] Replace the sidebar image portion of `Label(... systemImage:)` with `Image(destination.imageName, bundle: .module).renderingMode(.original)`, while preserving each row’s text and accessibility label.
- [ ] Run `make build`; verify every referenced resource resolves.

### Task 2: Split the crowded settings navigation

**Files:**
- Modify: `Sources/FreeTalker/UI/SettingsChrome.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`

**Interfaces:**
- Produces: destinations `privacy`, `recording`, `transcription`, `processing`, `launcher`, `storage`, `templates`, and `snippets`.
- Consumes: existing private General section builders and all existing General state.

- [ ] Write a failing presentation/organization regression test if a meaningful pure helper is extracted; otherwise record that SwiftUI layout has no snapshot harness and preserve existing behavioral tests.
- [ ] Replace the three-destination enum with the eight approved destinations, titles, and generated image names.
- [ ] Keep every destination mounted but make only the selected destination visible, enabled, hit-testable, and accessibility-visible.
- [ ] Reuse existing General section builders in focused pages: permissions/local privacy; recording; transcription; context/automation/cloud/output language; launcher; storage. Keep `GeneralSettingsView` state and modifiers on a single owner or split only with explicit bindings.
- [ ] Run `make test` and `make build`.

### Task 3: Persist and restore three independent panel positions

**Files:**
- Modify: `Sources/FreeTalker/Settings/AppSettings.swift`
- Modify: `Sources/FreeTalker/Models/FloatingControlSettings.swift`
- Modify: `Sources/FreeTalker/UI/FloatingControls/FloatingControlsController.swift`
- Modify: `Sources/FreeTalker/UI/HUDPanel.swift`
- Modify: `Sources/FreeTalker/UI/FloatingPanelGeometry.swift`
- Test: `Tests/FreeTalkerTests/FloatingControlsSettingsTests.swift`
- Test: `Tests/FreeTalkerTests/FloatingPanelGeometryTests.swift`
- Test: `Tests/FreeTalkerTests/FloatingPanelPolicyTests.swift`

**Interfaces:**
- Produces: optional `NormalizedWindowPosition` values for launcher, recording HUD, and transient HUD; reset operations.
- Consumes: legacy launcher edge/position and legacy `hudPosition` only for migration/default restoration.

- [ ] Write failing tests for each persisted position’s serialization/default/migration behavior and visible-frame restoration.
- [ ] Add the three settings keys and migration defaults. Preserve old user settings as described in the spec.
- [ ] Reuse normalized-origin geometry to restore/clamp each position against `visibleFrame`.
- [ ] Add a collapsed-launcher-only drag surface that calls `performDrag(with:)` and persists the final location; do not steal expanded button interaction.
- [ ] Stop re-anchoring recording/transient HUDs during re-render. Use their saved positions and persist dragging only after AppKit completes.
- [ ] Run focused position tests red then green; run `make test` and `make build`.

### Task 4: Add placement reset controls and final verification

**Files:**
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Test: existing settings/panel test files from Task 3.

**Interfaces:**
- Consumes: the three persisted position reset APIs.
- Produces: clear reset controls without adding product settings beyond placement.

- [ ] Replace the launcher edge/along-edge controls with explanatory placement text and reset buttons for Launcher, Recording HUD, and transient HUD.
- [ ] Retain explicit help explaining usable-area behavior: Dock visible stays above it; an auto-hidden Dock permits the physical screen bottom.
- [ ] Run `make test` and `make build`.
- [ ] Manually verify all sidebar pages, generated icons, drag persistence, reset behavior, display fallback, and Dock-visible/auto-hidden placement.

