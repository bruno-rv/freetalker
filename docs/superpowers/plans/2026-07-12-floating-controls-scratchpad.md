# Floating controls and scratchpad implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional edge-hover launcher, a draggable recording HUD, a
persistent rich-text scratchpad, and API-gated AI text transformations without
regressing external-app dictation or full-screen overlay behavior.

**Architecture:** Keep the launcher, recording HUD, and scratchpad as separate
AppKit-owned windows with explicit activation contracts. Add pure preference,
geometry, destination, document, and AI-availability types around the existing
`AppCoordinator`, then wire each surface to those tested seams. Reuse
`languagePin`, `CloudLLMSettingsSnapshot`, and `CloudLLMProcessor`; do not add a
second language setting or provider stack.

**Tech stack:** Swift 6.2, SwiftUI, AppKit, Swift Package Manager, Swift
Testing, UserDefaults, Keychain, RTF, and the existing cloud LLM processors.

## Global constraints

- Target macOS 26 and add no dependency.
- Keep the edge launcher disabled by default.
- Support Left, Right, Top, and Bottom with a normalized `0...1` position.
- Support only Automatic, English, and Portuguese in the new controls.
- Preserve the HUD's `.nonactivatingPanel`, `.floating`, `.canJoinAllSpaces`,
  `.stationary`, and `.fullScreenAuxiliary` behavior.
- Hovering or starting external dictation must not activate FreeTalker.
- Scratchpad dictation must never use external context, pasteboard insertion,
  synthetic paste, or Library recording.
- AI actions must use canonical `CloudLLMEligibility`; never fall back to
  `AppleFMProcessor`.
- Persist scratchpad content locally as RTF with atomic writes and preserve a
  corrupt source until the user makes a real edit.
- Keep the merged context-settings copy and behavior unchanged.

---

## File map

Create these focused units:

- `Sources/FreeTalker/Models/FloatingControlSettings.swift`: launcher edge and
  saved normalized window position value types.
- `Sources/FreeTalker/UI/FloatingPanelGeometry.swift`: pure multi-display frame
  calculations shared by launcher and HUD.
- `Sources/FreeTalker/UI/FloatingControls/FloatingControlsController.swift`:
  nonactivating panel lifecycle, tracking, and hover timing.
- `Sources/FreeTalker/UI/FloatingControls/FloatingControlsView.swift`: compact
  launcher visuals and actions.
- `Sources/FreeTalker/Core/RecordingDestination.swift`: explicit external or
  scratchpad recording destination and scratchpad routing protocol.
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadPersistence.swift`: safe RTF disk
  load/save.
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadDocument.swift`: text storage,
  stable insertion tokens, revisions, and debounced persistence.
- `Sources/FreeTalker/UI/Scratchpad/RichTextEditor.swift`: stable `NSTextView`
  bridge.
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadEditorController.swift`: native
  selection and formatting commands.
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift`:
  API-only transformation and eligibility presentation.
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift`: editor toolbar,
  dictation controls, AI controls, status, and errors.
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift`: normal
  focusable window and recording router.

Modify only these existing integration points:

- `Sources/FreeTalker/Settings/AppSettings.swift`
- `Sources/FreeTalker/UI/SettingsView.swift`
- `Sources/FreeTalker/UI/HUDPanel.swift`
- `Sources/FreeTalker/AppCoordinator.swift`
- `Sources/FreeTalker/App.swift`

---

### Task 1: Persist launcher, language, and HUD geometry preferences

**Files:**
- Create: `Sources/FreeTalker/Models/FloatingControlSettings.swift`
- Modify: `Sources/FreeTalker/Settings/AppSettings.swift`
- Test: `Tests/FreeTalkerTests/FloatingControlsSettingsTests.swift`

**Interfaces:**
- Produces: `LauncherEdge`, `NormalizedWindowPosition`,
  `AppSettings.edgeLauncherEnabled`, `edgeLauncherEdge`,
  `edgeLauncherPosition`, and `hudPosition`.
- Reuses: `AppSettings.languagePin` as the sole default language.

- [ ] **Step 1: Add failing settings tests**

Cover default-off behavior, all four edge values, clamping of finite and
non-finite positions, HUD JSON round-trip, invalid stored-value fallback, and
`languagePin` normalization:

```swift
@Test func launcherDefaultsAreSafe() async {
    let defaults = isolatedDefaults()
    let settings = await AppSettings(defaults: defaults)
    #expect(await settings.edgeLauncherEnabled == false)
    #expect(await settings.edgeLauncherEdge == .right)
    #expect(await settings.edgeLauncherPosition == 0.5)
    #expect(await settings.hudPosition == nil)
}

@Test(arguments: [(-1.0, 0.0), (0.4, 0.4), (2.0, 1.0),
                  (.infinity, 0.5), (.nan, 0.5)])
func launcherPositionClamps(input: Double, expected: Double) async {
    let settings = await AppSettings(defaults: isolatedDefaults())
    await MainActor.run { settings.edgeLauncherPosition = input }
    #expect(await settings.edgeLauncherPosition == expected)
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FloatingControlsSettingsTests
```

Expected: compilation fails because the new settings types and properties do
not exist.

- [ ] **Step 3: Add minimal value types and persistence**

```swift
enum LauncherEdge: String, CaseIterable, Codable, Sendable {
    case left, right, top, bottom
}

struct NormalizedWindowPosition: Codable, Equatable, Sendable {
    let displayID: String?
    let x: Double
    let y: Double
}
```

Add `@Published` settings with `didSet` persistence. Normalize the launcher
position with one helper:

```swift
nonisolated static func clampNormalizedPosition(_ value: Double) -> Double {
    guard value.isFinite else { return 0.5 }
    return min(max(value, 0), 1)
}
```

Decode `hudPosition` only when both coordinates are finite. Keep invalid data as
`nil`. Do not add a new language property.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the command from Step 2. Expected: all
`FloatingControlsSettingsTests` pass.

- [ ] **Step 5: Commit the settings slice**

```bash
git add Sources/FreeTalker/Models/FloatingControlSettings.swift \
  Sources/FreeTalker/Settings/AppSettings.swift \
  Tests/FreeTalkerTests/FloatingControlsSettingsTests.swift
git commit -m "Add floating control preferences"
```

### Task 2: Add pure floating-panel geometry

**Files:**
- Create: `Sources/FreeTalker/UI/FloatingPanelGeometry.swift`
- Test: `Tests/FreeTalkerTests/FloatingPanelGeometryTests.swift`

**Interfaces:**
- Consumes: `LauncherEdge`, `NormalizedWindowPosition`.
- Produces: `DisplayFrame` and pure launcher/HUD geometry functions.

- [ ] **Step 1: Write failing four-edge and restore tests**

```swift
@Test(arguments: LauncherEdge.allCases)
func launcherFrameStaysVisible(edge: LauncherEdge) {
    let screen = CGRect(x: 100, y: 200, width: 1200, height: 800)
    let frame = FloatingPanelGeometry.launcherFrame(
        edge: edge, position: 0.5,
        panelSize: CGSize(width: 180, height: 44), visibleFrame: screen)
    #expect(screen.contains(frame))
}

@Test func missingDisplayFallsBackAndClamps() {
    let fallback = DisplayFrame(id: "current", visibleFrame: .init(
        x: 0, y: 0, width: 800, height: 600))
    let saved = NormalizedWindowPosition(displayID: "gone", x: 1, y: 1)
    let origin = FloatingPanelGeometry.restoredOrigin(
        saved: saved, displays: [], fallback: fallback,
        panelSize: .init(width: 320, height: 80))
    #expect(origin.x <= 480)
    #expect(origin.y <= 520)
}
```

Also test endpoints, midpoint, nonzero screen origins, normalization round-trip,
content resize, and a minimum draggable visible area.

- [ ] **Step 2: Run tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FloatingPanelGeometryTests
```

Expected: compilation fails because `FloatingPanelGeometry` does not exist.

- [ ] **Step 3: Implement pure geometry**

```swift
struct DisplayFrame: Equatable, Sendable {
    let id: String
    let visibleFrame: CGRect
}

enum FloatingPanelGeometry {
    static func launcherFrame(
        edge: LauncherEdge, position: Double,
        panelSize: CGSize, visibleFrame: CGRect
    ) -> CGRect

    static func normalizedOrigin(
        frame: CGRect, display: DisplayFrame
    ) -> NormalizedWindowPosition

    static func restoredOrigin(
        saved: NormalizedWindowPosition?, displays: [DisplayFrame],
        fallback: DisplayFrame, panelSize: CGSize
    ) -> CGPoint

    static func clampedOrigin(
        _ origin: CGPoint, panelSize: CGSize, visibleFrame: CGRect,
        minimumVisible: CGSize = .init(width: 48, height: 32)
    ) -> CGPoint
}
```

Use AppKit global bottom-left coordinates. Map vertical edges bottom-to-top and
horizontal edges left-to-right. Clamp the complete launcher, but only the
minimum drag area for an oversized/restored HUD.

- [ ] **Step 4: Run tests and confirm GREEN**

Run Step 2. Expected: all geometry cases pass.

- [ ] **Step 5: Commit the geometry slice**

```bash
git add Sources/FreeTalker/UI/FloatingPanelGeometry.swift \
  Tests/FreeTalkerTests/FloatingPanelGeometryTests.swift
git commit -m "Add floating panel geometry"
```

### Task 3: Make the recording HUD draggable and restorable

**Files:**
- Modify: `Sources/FreeTalker/UI/HUDPanel.swift`
- Test: `Tests/FreeTalkerTests/FloatingPanelPolicyTests.swift`
- Test: `Tests/FreeTalkerTests/FloatingPanelGeometryTests.swift`

**Interfaces:**
- Consumes: `AppSettings.hudPosition`, `FloatingPanelGeometry`.
- Preserves: existing `HUDController` public methods and callbacks.

- [ ] **Step 1: Add failing HUD policy and resize tests**

Assert the panel remains nonactivating, non-key, non-main, floating, and has all
three collection behaviors. Add a geometry regression proving that changing
content size keeps the saved origin and clamps it instead of recentering.

```swift
#expect(panel.styleMask.contains(.nonactivatingPanel))
#expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
#expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
#expect(panel.collectionBehavior.contains(.stationary))
#expect(panel.canBecomeKey == false)
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FloatingPanelPolicyTests
```

Expected: tests cannot access a testable panel policy/drag configuration.

- [ ] **Step 3: Preserve origin across display refreshes**

Replace unconditional `position(panel)` in `display(mode:)` with:

1. Restore the saved/default origin only on the first presentation.
2. Capture the existing origin before `setContentSize`.
3. Restore that origin and clamp after resizing.
4. Re-clamp on `NSApplication.didChangeScreenParametersNotification`.

Expose an internal panel factory/policy helper for tests without exposing the
controller's panel publicly.

- [ ] **Step 4: Add a background-only drag surface**

Use an AppKit view behind the SwiftUI controls. On mouse-down outside controls,
call `window?.performDrag(with: event)`. On mouse-up/window move completion,
normalize the final frame against its screen and assign `settings.hudPosition`.
Do not enable `isMovableByWindowBackground` globally.

- [ ] **Step 5: Run HUD, geometry, and existing warning tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'FloatingPanelPolicyTests|FloatingPanelGeometryTests|HUDWarningPresentation'
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit the HUD slice**

```bash
git add Sources/FreeTalker/UI/HUDPanel.swift \
  Tests/FreeTalkerTests/FloatingPanelPolicyTests.swift \
  Tests/FreeTalkerTests/FloatingPanelGeometryTests.swift
git commit -m "Make the recording HUD draggable"
```

### Task 4: Build the optional edge-hover launcher

**Files:**
- Create:
  `Sources/FreeTalker/UI/FloatingControls/FloatingControlsController.swift`
- Create: `Sources/FreeTalker/UI/FloatingControls/FloatingControlsView.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Modify: `Sources/FreeTalker/App.swift`
- Test: `Tests/FreeTalkerTests/FloatingControlsPresentationTests.swift`

**Interfaces:**
- Consumes: launcher settings, geometry, `languagePin`.
- Produces: `FloatingControlsController.Callbacks` for dictation, scratchpad,
  Settings, and language selection.

- [ ] **Step 1: Add failing presentation-state tests**

Extract a small pure hover state reducer with collapsed, revealed, expanded,
and scheduled-collapse states. Test enter, transition between child controls,
grace-period cancellation, and disabled-setting hide behavior.

```swift
@Test func reenterCancelsScheduledCollapse() {
    var state = FloatingControlsHoverState.expanded
    state.reduce(.pointerExited)
    #expect(state.isCollapseScheduled)
    state.reduce(.pointerEntered)
    #expect(state == .expanded)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FloatingControlsPresentationTests
```

Expected: launcher presentation types do not exist.

- [ ] **Step 3: Implement the nonactivating controller**

```swift
@MainActor final class FloatingControlsController {
    struct Callbacks {
        var onDictation: () -> Void
        var onScratchpad: () -> Void
        var onOpenSettings: () -> Void
        var onLanguage: (String) -> Void
    }

    init(settings: AppSettings = .shared, callbacks: Callbacks)
    func start()
    func stop()
    func screenConfigurationDidChange()
}
```

Create a borderless `.nonactivatingPanel` that rejects key/main status and uses
`.floating`, `.canJoinAllSpaces`, and `.fullScreenAuxiliary`. Do not activate
the app for hover, dictation, or language. Use one `NSTrackingArea` with
`.activeAlways` and `.inVisibleRect`; remove/reinstall it after expansion,
reposition, and screen changes. Use a cancelable grace timer to prevent flicker.

- [ ] **Step 4: Render the compact controls**

Show microphone, scratchpad, Settings, and language controls. Provide `.help`
and accessibility labels for every control. Anchor expansion inward from the
selected edge so the complete frame stays visible. The UI must be visually
distinct from the supplied reference.

- [ ] **Step 5: Add the Settings section without touching context copy**

Add **Floating controls** near push-to-talk/hands-free settings. Bind enable,
edge picker, position slider, and the existing `languagePin`. Put edge labels
and explanations on `LauncherEdge`, following `LocalContextScope`'s pattern.

- [ ] **Step 6: Wire startup and intentional activation actions**

Retain one launcher controller for app lifetime. **Open FreeTalker** opens the
existing Settings window because this `LSUIElement` app has no main document
window and `MenuBarExtra` cannot be opened reliably. That action and
**Scratchpad** may activate FreeTalker; hover and other actions may not.

- [ ] **Step 7: Run focused and settings presentation tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'FloatingControls|LocalContextPresentationTests'
```

Expected: all selected tests pass and the exact context copy is unchanged.

- [ ] **Step 8: Commit the launcher slice**

```bash
git add Sources/FreeTalker/UI/FloatingControls \
  Sources/FreeTalker/UI/SettingsView.swift Sources/FreeTalker/App.swift \
  Tests/FreeTalkerTests/FloatingControlsPresentationTests.swift
git commit -m "Add optional edge-hover controls"
```

### Task 5: Introduce explicit recording destinations

**Files:**
- Create: `Sources/FreeTalker/Core/RecordingDestination.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Test: `Tests/FreeTalkerTests/RecordingDestinationTests.swift`
- Test: existing coordinator and automatic-style tests.

**Interfaces:**
- Produces: `ScratchpadInsertionToken`, `RecordingDestination`, and
  `ScratchpadRecordingRouting`.
- Preserves: existing external recording, insertion, Library, template, App
  Rule, and local-context behavior.

- [ ] **Step 1: Add failing destination-routing tests**

Use injected spies to prove external completion calls insertion and Library
recording, while scratchpad completion calls only the router. Cover preview,
success, cancellation, start failure, transcription failure, and state reset.

```swift
@MainActor protocol ScratchpadRecordingRouting: AnyObject {
    func updatePreview(_ text: String?, for token: ScratchpadInsertionToken)
    func completeRecording(_ text: String,
                           for token: ScratchpadInsertionToken) -> Bool
    func cancelRecording(for token: ScratchpadInsertionToken)
    func failRecording(_ message: String,
                       for token: ScratchpadInsertionToken)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter RecordingDestinationTests
```

Expected: destination and router types do not exist.

- [ ] **Step 3: Add destination value types and coordinator state**

```swift
struct ScratchpadInsertionToken: Hashable, Sendable {
    let id: UUID
}

enum RecordingDestination: Equatable, Sendable {
    case external
    case scratchpad(ScratchpadInsertionToken)
}
```

Store the destination when capture starts. Clear it on every terminal path and
start failure. Add:

```swift
@discardableResult
func startHandsFreeRecording(destination: RecordingDestination) -> Bool

func stopCurrentRecording()
```

Keep existing hotkey and HUD calls defaulting to `.external`.

- [ ] **Step 4: Extract transcription/refinement from side effects**

Create a private non-`Sendable` result value because the existing fallback
error may carry `Error`. Keep `processDictation` as the external wrapper around
the extracted stage, then insertion and Library recording. Do not weaken the
existing stop-time snapshot or safe-insertion checks.

- [ ] **Step 5: Route scratchpad without external side effects**

For `.scratchpad`, skip frontmost-app capture, local external context, App
Rules, pasteboard/insertion, and Library recording. Deliver temporary preview
and final refined text only through the weak scratchpad router. Apply the
one-shot/default language path but no destination-app language rule.

- [ ] **Step 6: Run destination and regression tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'RecordingDestinationTests|RecordingStateMachine'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'AutomaticStyle|ContextRouting'
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit the destination slice**

```bash
git add Sources/FreeTalker/Core/RecordingDestination.swift \
  Sources/FreeTalker/AppCoordinator.swift \
  Tests/FreeTalkerTests/RecordingDestinationTests.swift
git commit -m "Route recordings by explicit destination"
```

### Task 6: Persist a safe rich-text scratchpad document

**Files:**
- Create: `Sources/FreeTalker/UI/Scratchpad/ScratchpadPersistence.swift`
- Create: `Sources/FreeTalker/UI/Scratchpad/ScratchpadDocument.swift`
- Test: `Tests/FreeTalkerTests/ScratchpadPersistenceTests.swift`

**Interfaces:**
- Produces: `ScratchpadPersistence`, `ScratchpadDocument`, stable insertion
  token creation and validated replacement.

- [ ] **Step 1: Write failing RTF and corruption tests**

Test missing file, first save, replacement save, bold/italic/paragraph/list RTF
round-trip, corrupt RTF preservation, and insertion-token invalidation after an
intervening edit. Use a temporary directory per test.

```swift
@Test func corruptSourceIsNotOverwrittenUntilEdit() throws {
    let url = temporaryURL()
    try Data("not rtf".utf8).write(to: url)
    let result = ScratchpadPersistence(url: url).load()
    #expect(result.warning != nil)
    #expect(try Data(contentsOf: url) == Data("not rtf".utf8))
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScratchpadPersistenceTests
```

Expected: scratchpad persistence types do not exist.

- [ ] **Step 3: Implement RTF persistence**

Use `NSAttributedString.data(from:documentAttributes:)` with `.rtf`, and the
RTF initializer for loading. Use `NSString`/`NSRange` UTF-16 lengths. Write a
temporary sibling and replace the destination; move on the first save. Do not
use keyed unarchiving.

- [ ] **Step 4: Implement document revision and token safety**

```swift
@MainActor final class ScratchpadDocument: ObservableObject {
    @Published private(set) var warning: String?
    let textStorage: NSTextStorage

    func makeInsertionToken(selectedRange: NSRange)
        -> ScratchpadInsertionToken
    func replaceIfValid(token: ScratchpadInsertionToken,
                        with text: NSAttributedString,
                        undoActionName: String) -> Bool
    func scheduleSave()
    func flush() throws
}
```

Internally map token IDs to revision, UTF-16 range, and original substring.
Invalidate safely on unrelated edits. Never persist live preview or errors.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run Step 2. Expected: all persistence and corruption cases pass.

- [ ] **Step 6: Commit the persistence slice**

```bash
git add Sources/FreeTalker/UI/Scratchpad/ScratchpadPersistence.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadDocument.swift \
  Tests/FreeTalkerTests/ScratchpadPersistenceTests.swift
git commit -m "Add persistent scratchpad document"
```

### Task 7: Add the native rich-text editor and formatting commands

**Files:**
- Create: `Sources/FreeTalker/UI/Scratchpad/RichTextEditor.swift`
- Create: `Sources/FreeTalker/UI/Scratchpad/ScratchpadEditorController.swift`
- Test: `Tests/FreeTalkerTests/ScratchpadEditorTests.swift`

**Interfaces:**
- Consumes: `ScratchpadDocument.textStorage`.
- Produces: selection-aware heading, inline, list, clear-format, and
  transformation-range commands.

- [ ] **Step 1: Add failing formatting and undo tests**

Test bold/italic over selection and typing attributes, heading paragraph range,
bulleted and numbered `NSTextList` attributes, clear formatting, selection
replacement, UTF-16 text, and one-step undo.

```swift
@Test func boldWithEmptySelectionUpdatesTypingAttributes() async {
    let harness = await EditorHarness("Hello")
    await harness.select(NSRange(location: 5, length: 0))
    await harness.controller.toggleBold()
    #expect(await harness.textView.typingAttributes[.font] != nil)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScratchpadEditorTests
```

Expected: editor/controller types do not exist.

- [ ] **Step 3: Implement the stable `NSTextView` bridge**

Create one `NSTextView` inside an `NSScrollView`. Bind it to the document's
existing `NSTextStorage` once. Do not replace the attributed string from
`updateNSView`, because that destroys selection, undo, and typing attributes.
Notify the document of real edits through `NSTextViewDelegate`.

- [ ] **Step 4: Implement formatting commands**

```swift
enum ScratchpadHeading: Int, CaseIterable {
    case body, heading1, heading2
}

enum ScratchpadListKind: Equatable {
    case bulleted, numbered
}
```

Use `NSFontManager` for symbolic bold/italic traits, paragraph ranges for
headings/lists, `NSTextList` plus tab stops/indents for lists, and explicit
allowed attributes for clear formatting. Wrap each operation in one undo group
and schedule persistence once.

- [ ] **Step 5: Verify RTF list round-trip and GREEN tests**

Run `ScratchpadEditorTests` and `ScratchpadPersistenceTests`. Expected: all
pass, including semantic list attributes after reload.

- [ ] **Step 6: Commit the editor slice**

```bash
git add Sources/FreeTalker/UI/Scratchpad/RichTextEditor.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadEditorController.swift \
  Tests/FreeTalkerTests/ScratchpadEditorTests.swift
git commit -m "Add scratchpad rich text editing"
```

### Task 8: Add the scratchpad window and destination-aware dictation

**Files:**
- Create: `Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift`
- Create: `Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift`
- Modify: `Sources/FreeTalker/App.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Test: `Tests/FreeTalkerTests/ScratchpadRecordingTests.swift`

**Interfaces:**
- Consumes: document/editor controllers, recording destination API.
- Produces: one retained normal scratchpad window and
  `ScratchpadRecordingRouting` implementation.

- [ ] **Step 1: Add failing scratchpad recording tests**

Test insertion point, selected replacement, preview not entering storage,
cancel/error leaving content unchanged, invalidated token preserving recoverable
text, and no external insert/Library spy calls.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScratchpadRecordingTests
```

Expected: scratchpad window/router implementation does not exist.

- [ ] **Step 3: Implement the normal focusable window**

```swift
@MainActor final class ScratchpadWindowController: NSWindowController,
    ScratchpadRecordingRouting {
    static let shared = ScratchpadWindowController()
    func open()
    func startDictation()
}
```

Create a titled, closable, resizable window containing `ScratchpadView`.
`open()` may activate FreeTalker and make the window key. Flush the document on
close and `NSApplication.willTerminateNotification`.

- [ ] **Step 4: Wire scratchpad dictation**

Capture the selected range into a token, call
`startHandsFreeRecording(destination: .scratchpad(token))`, render preview
outside `textStorage`, and replace through `replaceIfValid` only on completion.
Expose cancel/stop states without synthetic paste or external context capture.

- [ ] **Step 5: Add menu and launcher entry points**

Add **Scratchpad…** to the menu bar. Route the launcher scratchpad callback to
the same retained controller. Register it as the coordinator's weak router.

- [ ] **Step 6: Run scratchpad and destination tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'ScratchpadRecordingTests|RecordingDestinationTests|ScratchpadEditorTests'
```

Expected: all selected tests pass.

- [ ] **Step 7: Commit the scratchpad integration slice**

```bash
git add Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift \
  Sources/FreeTalker/App.swift Sources/FreeTalker/AppCoordinator.swift \
  Tests/FreeTalkerTests/ScratchpadRecordingTests.swift
git commit -m "Add destination-aware scratchpad dictation"
```

### Task 9: Add API-only scratchpad transformations

**Files:**
- Create:
  `Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift`
- Modify: `Sources/FreeTalker/Settings/AppSettings.swift`
- Test: `Tests/FreeTalkerTests/ScratchpadAIActionTests.swift`

**Interfaces:**
- Consumes: `CloudLLMSettingsSnapshot`, `CloudLLMEligibility`,
  `CloudLLMProcessor`, `Template`.
- Produces: `ScratchpadAIAction`, `ScratchpadTransforming`,
  `ScratchpadAIAvailability`.

- [ ] **Step 1: Add failing eligibility and request tests**

Table-test eligible keyed providers, missing key, invalid URL/model/port,
keyless HTTP loopback, rejected non-loopback keyless, and rejected HTTPS
loopback keyless. Test empty input, missing custom instruction, same-snapshot
use, language-preserving prompts, empty response rejection, and no local
fallback.

```swift
@Test func missingKeyReasonMatchesTooltipAndAccessibility() {
    let availability = ScratchpadAIAvailability.make(
        eligibility: .missingAPIKey, hasInput: true,
        hasInstruction: true, providerName: "Anthropic")
    #expect(availability.enabled == false)
    #expect(availability.tooltip == availability.accessibilityHelp)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ScratchpadAIActionTests
```

Expected: scratchpad AI types do not exist.

- [ ] **Step 3: Make cloud snapshots safe value inputs**

Add `Equatable` and `Sendable` to `CloudLLMSettingsSnapshot` and
`CloudLLMEligibility`. Their stored values are value types that satisfy both
contracts. Do not change eligibility logic.

- [ ] **Step 4: Implement the transformation service**

```swift
enum ScratchpadAIAction: Equatable, Sendable {
    case improveWriting
    case expand
    case condense
    case custom(String)
}

protocol ScratchpadTransforming: Sendable {
    func transform(_ text: String, action: ScratchpadAIAction,
                   snapshot: CloudLLMSettingsSnapshot) async throws -> String
}
```

Build a purpose-specific `Template` for the selected action and call
`CloudLLMProcessor(snapshot: snapshot).process(...)`. Capture and validate one
snapshot at click time. Require transformed text only, preserve input language,
trim the response, and reject empty output. Never call `AppleFMProcessor`.

- [ ] **Step 5: Implement one canonical disabled-reason presenter**

`ScratchpadAIAvailability` must return the same explanation for tooltip and
accessibility help. Priority: empty text, in-flight action, missing custom
instruction, invalid API configuration, then missing API key.

- [ ] **Step 6: Run focused tests and confirm GREEN**

Run Step 2. Expected: all eligibility, snapshot, prompt, and error cases pass.

- [ ] **Step 7: Commit the AI service slice**

```bash
git add Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift \
  Sources/FreeTalker/Settings/AppSettings.swift \
  Tests/FreeTalkerTests/ScratchpadAIActionTests.swift
git commit -m "Add scratchpad AI transformations"
```

### Task 10: Integrate AI actions into the scratchpad editor

**Files:**
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadEditorController.swift`
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift`
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift`
- Test: `Tests/FreeTalkerTests/ScratchpadAIActionTests.swift`

**Interfaces:**
- Consumes: transformation service and availability.
- Produces: selection/full-document source snapshots and safe one-undo
  replacement.

- [ ] **Step 1: Add failing source-drift and replacement tests**

Test selection precedence, whole-document fallback, concurrent source edits,
one-step undo, preserved surrounding attributes, failure/cancel/empty response,
and custom-instruction validation.

- [ ] **Step 2: Run tests and confirm RED**

Run `swift test --filter ScratchpadAIActionTests`. Expected: editor integration
tests fail because snapshots and replacement are absent.

- [ ] **Step 3: Add verified source snapshots**

```swift
struct ScratchpadSourceSnapshot: Equatable {
    let range: NSRange
    let originalText: String
    let revision: Int
}

func captureTransformationSource() -> ScratchpadSourceSnapshot?
func applyTransformation(_ result: String,
                         to snapshot: ScratchpadSourceSnapshot) -> Bool
```

Use UTF-16 ranges. Replace only when revision/range/original text still match.
Group the replacement as one undoable edit and preserve surrounding paragraph
style while using appropriate inline attributes from the source range.

- [ ] **Step 4: Add visible, gated AI controls**

Render Improve writing, Expand, Condense, and Custom instruction. Keep controls
visible while disabled. Put `.help(reason)` on a non-disabled wrapper because a
disabled SwiftUI button may not receive hover. Add the same reason through
`.accessibilityHelp`. Show progress for one action and non-destructive errors.

- [ ] **Step 5: Run AI, editor, and persistence tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'ScratchpadAIActionTests|ScratchpadEditorTests|ScratchpadPersistenceTests'
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit the AI UI slice**

```bash
git add Sources/FreeTalker/UI/Scratchpad/ScratchpadEditorController.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift \
  Tests/FreeTalkerTests/ScratchpadAIActionTests.swift
git commit -m "Add scratchpad AI controls"
```

### Task 11: Verify the complete behavior and document user controls

**Files:**
- Modify: `README.md`
- Modify only if a defect is found: files from Tasks 1-10 and their tests.

**Interfaces:**
- Consumes: the complete launcher, HUD, recording destination, scratchpad, and
  AI flows.
- Produces: release evidence and concise user-facing documentation.

- [ ] **Step 1: Add concise README usage and privacy copy**

Document how to enable/reposition the edge launcher, select default language,
drag the HUD, open/use the scratchpad, and configure API-backed AI actions.
State that selected scratchpad text is sent to the configured cloud endpoint.

- [ ] **Step 2: Run the full test suite**

```bash
make test
```

Expected: exit code `0` with no failed tests.

- [ ] **Step 3: Assemble the release app**

```bash
make app
```

Expected: exit code `0`, release build completes, and the app bundle is
assembled and ad-hoc signed.

- [ ] **Step 4: Run the manual full-screen and focus matrix**

Verify launcher off-by-default; all edges and slider endpoints; hover grace;
Automatic/English/Portuguese synchronization; external focus retention; HUD
drag restore; display disconnect; Spaces; another app in full-screen;
scratchpad insertion/selection/live preview; formatting persistence; AI
selection/document actions; configuration tooltips; VoiceOver; and source-edit
during an AI request. Record each result in the implementation handoff.

- [ ] **Step 5: Inspect the final diff and working tree**

```bash
git diff --check
git status --short
git diff --stat origin/main...HEAD
```

Expected: no whitespace errors; only planned files plus the user's pre-existing
untracked artifacts; no accidental context-copy changes.

- [ ] **Step 6: Commit documentation or final verification fixes**

```bash
git add README.md
git commit -m "Document floating controls and scratchpad"
```

If verification required code fixes, stage only the related planned files and
use a commit message that names the corrected behavior.

## Execution order and review gates

Tasks 1 and 2 are independent foundations and may run in parallel with disjoint
files. Task 3 depends on Tasks 1-2. Task 4 depends on Tasks 1-2. Task 5 depends
on Task 1. Task 6 can begin after Task 5 defines the token type. Task 7 depends
on Task 6. Task 8 depends on Tasks 4-7. Task 9 can run after Task 1 and in
parallel with Tasks 6-8. Task 10 depends on Tasks 7 and 9. Task 11 runs last.

After every task, review both specification compliance and code quality before
starting a dependent task. Do not accept an agent's success report without
inspecting its diff and rerunning the stated focused command.
