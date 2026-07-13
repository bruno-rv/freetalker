# Settings Navigation and Panel Placement Design

## Goal

Replace the crowded General settings page with focused destinations, use original generated image icons for navigation, and let FreeTalker’s floating surfaces remember a user-chosen position without covering the macOS Dock or menu bar.

## Navigation

The sidebar will contain these destinations, in order:

1. Privacy
2. Recording
3. Transcription
4. Context & Processing
5. Launcher
6. Storage
7. Templates
8. Snippets

Existing settings move without changing their models or behavior:

- Privacy contains permission status and local-context privacy guidance.
- Recording contains push-to-talk, redo, Voice Edit, and hands-free controls.
- Transcription contains microphone, suppression, engines, speech models, Cloud STT, live preview, and vocabulary.
- Context & Processing contains text context, automatic template selection, app rules, output language, and cloud LLM controls.
- Launcher contains launcher visibility and placement controls.
- Storage contains recovery and imported-media retention.
- Templates and Snippets retain their existing editors.

## Icon assets

Create eight original 128px PNG navigation icons, one per destination. They use the clean circular waveform language from the supplied reference: dark circular field, luminous blue/purple/teal symbol, restrained depth, no text, logo, or decorative surrounding tile. The images are package resources displayed as decorative 20–22pt sidebar artwork; the destination title remains the accessibility label.

## Floating surface placement

The launcher, recording HUD, and transient/status HUD each persist a separate `NormalizedWindowPosition` with display identity. A drag starts only from a non-interactive background/handle and persists the selected panel’s final frame after AppKit finishes the drag. Existing controls and keyboard handling remain available.

All positions are clamped to `NSScreen.visibleFrame`:

- With the Dock visible, panels stop above it and below the menu bar.
- With an auto-hidden Dock, `visibleFrame` reaches the physical bottom, so a panel can reach the screen edge.

Existing launcher edge/along-edge settings migrate to the first saved launcher position. The existing general HUD position migrates to the transient HUD; the recording HUD starts at the legacy launcher location until the user drags it. Each surface gets a reset action.

## Boundaries

Do not make panels key/main or enable `isMovableByWindowBackground`. Do not change dictation, hotkey, template, snippet, or cloud-processing behavior. Do not overlap the Dock/menu bar while they are visible.

## Verification

- Add focused persistence/migration and geometry tests for all three surface positions.
- Add a regression test proving a recording HUD drag survives a re-render.
- Run `make test` and `make build`.
- Manually verify sidebar navigation, generated assets, drags, resets, display changes, and Dock-visible versus Dock-hidden placement.
