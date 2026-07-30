# Settings Icon Redesign

## Goal

Replace all ten settings sidebar icons with a coherent image set that sits
directly on the adaptive macOS sidebar background. Every destination must have a
distinct, legible symbol at the existing 28-point display size.

## Visual direction

Use floating luminous glyphs rather than enclosing circles or tiles. Each icon
has a transparent outer canvas, a compact three-dimensional frosted-glass
symbol, bright white highlights, cyan edge light, and a restrained colored
glow. The artwork must not include a background fill, floor plane, cast shadow,
text, watermark, enclosing medallion, or decorative tile.

All final assets remain 360 × 360 RGBA PNGs with generous transparent padding.
The visible symbol stays centered and uses a consistent scale across the set.
This preserves the sidebar's adaptive `windowBackgroundColor` in light and dark
appearances and avoids a visible rectangular asset boundary.

## Icon semantics and accents

| Destination | Symbol | Accent |
| --- | --- | --- |
| Privacy | Shield with keyhole | Blue |
| Recording | Studio microphone | Teal |
| Transcription | Audio waveform | Violet |
| Processing | Connected processing spark | Cyan-blue |
| Launcher | Launch arrow | Blue |
| Storage | Archive box | Amber |
| Templates | Template sheet | Cyan-blue |
| Snippets | Quotation snippet | Violet |
| Library | Stacked recording cards | Teal |
| Usage Statistics | Ascending bars with trend | Violet-blue |

The silhouettes must remain distinguishable at 28 points. In particular,
Library and Usage Statistics must be bespoke artwork rather than copies of
Templates.

## Integration

Replace the existing files under
`Sources/FreeTalker/Resources/SettingsIcons/` without changing their filenames.
No Swift UI change is required: `SettingsDestination.imageName` already maps
each destination to its resource, and `SettingsSidebar` already renders the
images at 28 × 28 points with high interpolation.

## Verification

- Extend `SettingsIconResourceTests` to require unique PNG data in addition to
  the existing loadability, 360 × 360 size, and transparent-corner checks.
- Run the focused settings icon resource test.
- Run the repository's build and test commands.
- Inspect the rendered sidebar at its real icon size in both light and dark
  appearances, including selected and unselected rows. Confirm that no icon has
  a visible rectangular boundary and that all ten symbols are distinct.

## Boundaries

This change does not alter settings navigation, sidebar metrics, accessibility,
destination ordering, or settings behavior. It adds no new runtime dependency.
