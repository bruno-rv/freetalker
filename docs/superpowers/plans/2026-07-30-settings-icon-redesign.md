# Settings Icon Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all ten settings sidebar images with unique floating luminous glyphs that blend into the adaptive macOS background.

**Architecture:** Preserve the existing filename-based resource contract and sidebar rendering code. Generate each icon independently on a removable chroma-key field, convert it to an RGBA PNG with transparent outer pixels, then use the existing Swift resource test plus a new uniqueness assertion to enforce the asset contract.

**Tech Stack:** OpenAI built-in image generation, PNG/RGBA assets, the imagegen chroma-key removal helper, Swift 6.2, Swift Testing, SwiftUI/AppKit.

## Global Constraints

- Final assets are 360 × 360 RGBA PNGs under `Sources/FreeTalker/Resources/SettingsIcons/`.
- The outer canvas is transparent; do not include a background fill, floor plane, cast shadow, text, watermark, enclosing medallion, or decorative tile.
- Use a centered frosted-glass glyph with bright white highlights, cyan edge light, restrained glow, generous padding, and a consistent visual scale.
- Preserve the ten existing filenames and add no runtime dependency.
- Do not change navigation, sidebar metrics, accessibility, destination ordering, or settings behavior.

---

## File Map

- Modify `Tests/FreeTalkerTests/SettingsIconResourceTests.swift`: reject duplicate image data across settings destinations.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/privacy.png`: blue shield with keyhole.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/recording.png`: teal studio microphone.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/transcription.png`: violet audio waveform.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/processing.png`: cyan-blue connected processing spark.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/launcher.png`: blue launch arrow.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/storage.png`: amber archive box.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/templates.png`: cyan-blue template sheet.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/snippets.png`: violet quotation snippet.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/library.png`: teal stacked recording cards.
- Replace `Sources/FreeTalker/Resources/SettingsIcons/stats.png`: violet-blue ascending bars with trend.

### Task 1: Enforce and produce a unique transparent icon set

**Files:**

- Modify: `Tests/FreeTalkerTests/SettingsIconResourceTests.swift`
- Replace: `Sources/FreeTalker/Resources/SettingsIcons/{privacy,recording,transcription,processing,launcher,storage,templates,snippets,library,stats}.png`

**Interfaces:**

- Consumes: `SettingsDestination.allCases`, `SettingsDestination.imageName`, and `SettingsIconResources.bundle`.
- Produces: ten unique 360 × 360 RGBA PNG resources addressable by the existing destination raw values.

- [ ] **Step 1: Add a failing duplicate-resource regression**

Add this test inside `SettingsIconResourceTests`:

```swift
@Test func everySettingsDestinationHasUniqueArtwork() throws {
    let imageData = try SettingsDestination.allCases.map { destination in
        let url = try #require(SettingsIconResources.bundle.url(
            forResource: destination.imageName,
            withExtension: "png"
        ))
        return try Data(contentsOf: url)
    }

    #expect(Set(imageData).count == SettingsDestination.allCases.count)
}
```

- [ ] **Step 2: Run the focused test and confirm the current duplicates fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SettingsIconResourceTests
```

Expected: `everySettingsDestinationHasUniqueArtwork` fails because Templates,
Library, and Usage Statistics currently share identical PNG data.

- [ ] **Step 3: Generate the ten chroma-key source images**

Use the built-in image-generation tool once per icon. Copy the returned files to
these exact source paths before post-processing:

```text
tmp/settings-icons/privacy-source.png
tmp/settings-icons/recording-source.png
tmp/settings-icons/transcription-source.png
tmp/settings-icons/processing-source.png
tmp/settings-icons/launcher-source.png
tmp/settings-icons/storage-source.png
tmp/settings-icons/templates-source.png
tmp/settings-icons/snippets-source.png
tmp/settings-icons/library-source.png
tmp/settings-icons/stats-source.png
```

Use this shared prompt contract for every call:

```text
Use case: stylized-concept
Asset type: 28-point macOS settings sidebar icon, delivered on a 360 × 360 canvas
Primary request: Create one centered floating luminous 3D glyph using the destination-specific subject line from the numbered list in this step.
Style/medium: compact frosted-glass symbol, premium macOS-quality 3D icon, bright white highlights, cyan edge lighting, restrained colored inner glow
Composition/framing: single centered glyph, consistent optical scale, fully contained, generous uniform padding, bold silhouette readable at 28 points
Scene/backdrop: perfectly flat solid #00ff00 chroma-key background for removal
Constraints: one symbol only; the background must be one uniform color with no shadows, gradients, texture, reflections, floor plane, or lighting variation; keep the subject fully separated from the background with crisp edges; do not use #00ff00 in the subject
Avoid: enclosing circle, medallion, square, squircle, decorative tile, cast shadow, contact shadow, reflection, text, letters, numbers, watermark, tiny details
```

Use these exact subject lines and accent instructions:

1. `privacy.png`: “a protective shield with a clearly cut keyhole; sapphire-blue inner glow.”
2. `recording.png`: “a classic studio microphone with a simple stand; teal inner glow.”
3. `transcription.png`: “a balanced horizontal audio waveform with five distinct rounded peaks; violet inner glow.”
4. `processing.png`: “a four-node connected processing flow converging on a central four-point spark; cyan-blue inner glow.”
5. `launcher.png`: “a clean upward-right launch arrow with subtle speed fins; electric-blue inner glow.”
6. `storage.png`: “a compact archive box with lid and one centered handle slot; amber-orange inner glow.”
7. `templates.png`: “one document sheet with two structured content blocks and a small folded corner; cyan-blue inner glow.”
8. `snippets.png`: “a paired quotation-mark symbol inside a short open text fragment, without any enclosing tile; violet inner glow.”
9. `library.png`: “three offset stacked audio recording cards, each with one short waveform line; teal inner glow.”
10. `stats.png`: “three ascending rounded bars crossed by one clean rising trend line; violet-blue inner glow.”

- [ ] **Step 4: Convert every chroma-key source to a transparent final PNG**

Run the installed helper for all ten explicit names:

```bash
mkdir -p tmp/settings-icons
for icon_name in privacy recording transcription processing launcher storage templates snippets library stats; do
  python /Users/bruno/.codex/skills/.system/imagegen/scripts/remove_chroma_key.py \
    --input "tmp/settings-icons/${icon_name}-source.png" \
    --out "Sources/FreeTalker/Resources/SettingsIcons/${icon_name}.png" \
    --auto-key border \
    --soft-matte \
    --transparent-threshold 12 \
    --opaque-threshold 220 \
    --despill
done
```

If one icon has a visible green fringe, rerun only that icon once with
`--edge-contract 1`.

- [ ] **Step 5: Normalize dimensions without changing transparency**

Normalize all final PNGs to the resource contract:

```bash
for icon_path in Sources/FreeTalker/Resources/SettingsIcons/*.png; do
  sips --resampleHeightWidth 360 360 "$icon_path"
done
```

Then confirm all ten dimensions:

```bash
sips -g pixelWidth -g pixelHeight \
  Sources/FreeTalker/Resources/SettingsIcons/*.png
```

Expected: every image reports `pixelWidth: 360` and `pixelHeight: 360`.

- [ ] **Step 6: Inspect the full set before accepting it**

Open each final PNG at original resolution. Check every item against its exact
subject line, confirm the ten silhouettes are distinct, confirm consistent
optical scale and padding, and reject any image containing a disc, tile,
background gradient, text, watermark, clipped edge, excessive glow, or
green fringe. Regenerate only rejected icons with one targeted correction.

- [ ] **Step 7: Run the focused resource test**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter SettingsIconResourceTests
```

Expected: all settings icon resource tests pass, including size, alpha,
transparent corner, and unique-data requirements.

- [ ] **Step 8: Commit the tested asset set**

```bash
git add Tests/FreeTalkerTests/SettingsIconResourceTests.swift \
  Sources/FreeTalker/Resources/SettingsIcons
git commit -m "feat(settings): redesign sidebar icons"
```

### Task 2: Verify build integration and adaptive-background rendering

**Files:**

- Verify only: `Sources/FreeTalker/UI/SettingsChrome.swift`
- Verify only: `Sources/FreeTalker/Resources/SettingsIcons/*.png`

**Interfaces:**

- Consumes: the ten unique PNGs produced by Task 1.
- Produces: evidence that the unchanged settings sidebar loads and renders the new resources in the app.

- [ ] **Step 1: Run the full test suite**

Run:

```bash
make test
```

Expected: the complete Swift test suite exits with status 0 and reports no
failures.

- [ ] **Step 2: Build the application target**

Run:

```bash
make build
```

Expected: the release build exits with status 0.

- [ ] **Step 3: Render the real settings sidebar without installing the app**

Assemble an ad-hoc signed local bundle without calling the destructive
`make app`/`make install` targets:

```bash
CODESIGN_IDENTITY=- make bundle
open FreeTalker.app
```

Open Settings and inspect all ten destinations. Do not replace the copy in
`/Applications`.

- [ ] **Step 4: Inspect dark and light appearances**

In both macOS appearances, inspect selected and unselected sidebar rows at the
real 28-point icon size. Confirm:

- the sidebar background remains continuous through every transparent canvas;
- no rectangular, circular, or tiled image background is visible;
- every glyph is recognizable and visually centered;
- white highlights remain legible in light appearance;
- glow does not bloom into neighboring labels;
- Library and Usage Statistics are immediately distinct from Templates and
  from each other.

Capture one dark and one light settings screenshot as verification evidence,
without replacing existing README screenshots unless explicitly requested.

- [ ] **Step 5: Review the final diff and status**

Run:

```bash
git diff HEAD^ -- Tests/FreeTalkerTests/SettingsIconResourceTests.swift \
  Sources/FreeTalker/Resources/SettingsIcons
git status --short
```

Expected: the commit contains only the ten icon replacements and the focused
regression test; the worktree has no unintended tracked changes.
