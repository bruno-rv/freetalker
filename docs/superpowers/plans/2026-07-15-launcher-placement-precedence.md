# Launcher Placement Precedence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make edge and along-edge settings replace stale dragged launcher
coordinates immediately and persist the user's most recent placement action.

**Architecture:** `AppSettings` invalidates the saved free-position override
when an edge control changes. `FloatingControlsController` consumes the
position emitted by Combine instead of rereading the pre-assignment property,
then materializes and persists coordinates through the existing geometry.

**Tech Stack:** Swift 6.2, SwiftUI Observation and Combine, AppKit geometry,
Swift Testing, macOS 26.

## Global constraints

- The user's most recent settings change or drag wins.
- Changing screen edge or along-edge position clears the free-position override.
- Manual dragging creates a new persisted free-position override.
- Keep screen-coordinate calculations out of `AppSettings`.
- Do not change floating-panel geometry formulas or add a placement mode.
- Do not change recording or transient HUD positions.
- Do not add a package dependency.

---

### Task 1: Honor edge settings after manual dragging

**Files:**

- Modify: `Sources/FreeTalker/Settings/AppSettings.swift:140-195`
- Modify:
  `Sources/FreeTalker/UI/FloatingControls/FloatingControlsController.swift`
  at lines 128-327
- Modify: `Tests/FreeTalkerTests/FloatingControlsSettingsTests.swift`

**Interfaces:**

- Consumes: `edgeLauncherEdge`, `edgeLauncherPosition`,
  `launcherPanelPosition`, and existing `FloatingPanelGeometry` functions.
- Produces: deterministic settings precedence and
  `show(savedPosition:)` / `renderAndPosition(savedPosition:)` controller
  paths.

- [ ] **Step 1: Write failing edge-precedence tests**

Extend `FloatingControlsSettingsTests.swift` with a parameterized test over
`LauncherEdge.allCases`. For every edge:

```swift
@Test("changing edge clears drag and rematerializes placement",
      arguments: LauncherEdge.allCases)
func changingEdge(edge: LauncherEdge) throws {
    let fixture = try FloatingSettingsFixture()
    fixture.settings.edgeLauncherPosition = 0.25
    fixture.settings.launcherPanelPosition = NormalizedWindowPosition(
        displayID: "main", x: 1, y: 0.5
    )

    fixture.settings.edgeLauncherEdge = edge

    #expect(fixture.settings.launcherPanelPosition == nil)
    #expect(fixture.defaults.data(forKey: "launcherPanelPosition") == nil)
    let visible = CGRect(x: 100, y: 80, width: 1_000, height: 700)
    let size = CGSize(width: 54, height: 54)
    let saved = FloatingPanelGeometry.legacyLauncherPosition(
        edge: edge,
        position: 0.25,
        panelSize: size,
        visibleFrame: visible,
        displayID: "main"
    )
    let origin = FloatingPanelGeometry.restoredOrigin(
        saved: saved, panelSize: size, visibleFrame: visible
    )
    let frame = CGRect(origin: origin, size: size)
    assert(frame: frame, touches: edge, visibleFrame: visible,
           alongEdgePosition: 0.25)
}
```

Implement the fixture and `assert` helper inside the test file using the same
isolated `UserDefaults` pattern as existing tests. Boundary assertions use
`minX`, `maxX`, `minY`, or `maxY` for the requested edge and the normalized
available span for the other axis.

Add these two tests:

```swift
@Test("changing along-edge position clears drag override")
func changingAlongEdgePosition() throws {
    let fixture = try FloatingSettingsFixture()
    fixture.settings.edgeLauncherEdge = .bottom
    fixture.settings.launcherPanelPosition = NormalizedWindowPosition(
        displayID: "main", x: 1, y: 0.5
    )

    fixture.settings.edgeLauncherPosition = 0.75

    #expect(fixture.settings.launcherPanelPosition == nil)
    #expect(fixture.defaults.data(forKey: "launcherPanelPosition") == nil)
}

@Test("drag after settings change becomes relaunch position")
func dragWinsAfterSettingsChange() throws {
    let fixture = try FloatingSettingsFixture()
    fixture.settings.edgeLauncherEdge = .bottom
    fixture.settings.edgeLauncherPosition = 0.75
    let dragged = NormalizedWindowPosition(
        displayID: "secondary", x: 0.42, y: 0.38
    )
    fixture.settings.launcherPanelPosition = dragged

    let reloaded = AppSettings(defaults: fixture.defaults)
    #expect(reloaded.edgeLauncherEdge == .bottom)
    #expect(reloaded.edgeLauncherPosition == 0.75)
    #expect(reloaded.launcherPanelPosition == dragged)
}
```

- [ ] **Step 2: Run the focused suite and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter FloatingControlsSettingsTests
```

Expected: the edge and slider tests fail because the saved launcher position
is not cleared.

- [ ] **Step 3: Invalidate the saved free position in settings**

In `AppSettings`, preserve current clamping and persistence, then reset only the
launcher override when the effective edge or along-edge value changes:

```swift
@Published var edgeLauncherEdge: LauncherEdge {
    didSet {
        defaults.set(edgeLauncherEdge.rawValue, forKey: Keys.edgeLauncherEdge)
        guard edgeLauncherEdge != oldValue else { return }
        resetLauncherPanelPosition()
    }
}

@Published var edgeLauncherPosition: Double {
    didSet {
        let clamped = min(max(edgeLauncherPosition, 0), 1)
        if edgeLauncherPosition != clamped {
            edgeLauncherPosition = clamped
            return
        }
        defaults.set(clamped, forKey: Keys.edgeLauncherPosition)
        guard clamped != oldValue else { return }
        resetLauncherPanelPosition()
    }
}
```

Use the repository's existing key names and existing
`resetLauncherPanelPosition()` implementation rather than duplicating key
removal.

- [ ] **Step 4: Render from the Combine-emitted position snapshot**

Change the launcher settings subscription from discarding the emitted position
to passing it through:

```swift
launcherSettings
    .sink { [weak self] enabled, savedPosition in
        guard let self else { return }
        if enabled {
            self.show(savedPosition: savedPosition)
        } else {
            self.hide()
        }
    }
```

Change the relevant controller methods to:

```swift
private func show(savedPosition: NormalizedWindowPosition?)

private func renderAndPosition(
    savedPosition: NormalizedWindowPosition?
)
```

All non-publisher calls pass `settings.launcherPanelPosition`. Inside
`renderAndPosition`, resolve from the passed snapshot. When it is `nil`, call
the existing `legacyLauncherPosition`, persist that result, and use it for
`restoredOrigin`. Do not reread `settings.launcherPanelPosition` before the
emitted `nil` assignment finishes.

- [ ] **Step 5: Run focused, related, and full verification**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter FloatingControlsSettingsTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter \
'FloatingControlsSettingsTests|FloatingPanelGeometryTests|\
FloatingControlsPresentationTests'
make test
make app
git diff --check
```

Expected: all suites and build pass with no diff errors.

- [ ] **Step 6: Perform the placement smoke flow**

Enable the launcher, drag it to the right, select **Bottom**, and verify an
immediate move. Repeat **Top**, **Left**, and **Right**; move the along-edge
slider; drag again; quit and relaunch. Repeat on a secondary display with menu
bar or Dock insets.

- [ ] **Step 7: Commit the coherent fix**

```bash
git add Sources/FreeTalker/Settings/AppSettings.swift \
  Sources/FreeTalker/UI/FloatingControls/FloatingControlsController.swift \
  Tests/FreeTalkerTests/FloatingControlsSettingsTests.swift
git commit -m "fix: honor launcher placement settings after drag"
```
