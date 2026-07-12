# Context Settings Clarity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make context capture and automatic template selection understandable through accurate labels, visible descriptions, and explicit hover help without changing behavior or persisted values.

**Architecture:** Keep scope-specific presentation copy beside `LocalContextScope` so `SettingsView` renders exhaustive metadata. Split the combined SwiftUI section into two sections bound to the existing settings properties. Add focused Swift Testing coverage for exact copy and stable raw values.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, macOS 26

## Global Constraints

- Do not change `LocalContextScope` cases, raw values, `Codable` behavior, settings keys, defaults, or migration behavior.
- Do not change context capture, template resolution, permissions, processor routing, or privacy behavior.
- The selected scope's visible description is authoritative; picker-menu tooltips are supplemental only.
- Use the exact copy from `docs/superpowers/specs/2026-07-12-context-settings-clarity-design.md`.
- Preserve the existing conditional Accessibility and Screen Recording warnings.

---

### Task 1: Context presentation metadata and Settings layout

**Files:**
- Modify: `Sources/FreeTalker/Models/LocalContextScope.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Create: `Tests/FreeTalkerTests/LocalContextPresentationTests.swift`

**Interfaces:**
- Consumes: `AppSettings.localContextScope`, `AppSettings.automaticStyleEnabled`, and current permission state in `SettingsView`.
- Produces: `LocalContextScope.displayName`, `LocalContextScope.explanation`, and exact Settings help copy.

- [ ] **Step 1: Write the failing presentation tests**

Create a Swift Testing suite that checks every scope's stable raw value, approved display name, and approved explanation. Add a test that `SettingsView.automaticTemplateHelp` contains `App Rule`, the four built-in template names, and `Active Template`.

```swift
@Test func scopePresentationCopyIsExactAndRawValuesStayStable() {
    let expected: [(LocalContextScope, String, String, String)] = [
        (.off, "off", "None", "Does not read nearby text. The destination app may still be used for App Rules and automatic template selection."),
        (.selectedText, "selectedText", "Selected text", "Reads only the selected text in the destination app. Requires Accessibility permission."),
        (.focusedField, "focusedField", "Current text field", "Reads the full focused editable field, excluding secure fields. Requires Accessibility permission."),
        (.activeWindow, "activeWindow", "Visible text in current window", "Reads text exposed by the current window's accessibility tree. Secure content is excluded. Requires Accessibility permission."),
        (.windowOCR, "windowOCR", "Current window screenshot (OCR)", "Takes one screenshot of the destination window and reads it with Apple Vision. Requires Screen Recording permission; the image is discarded after OCR.")
    ]
    #expect(LocalContextScope.allCases.count == expected.count)
    for (scope, raw, name, explanation) in expected {
        #expect(scope.rawValue == raw)
        #expect(scope.displayName == name)
        #expect(scope.explanation == explanation)
    }
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalContextPresentationTests`.

Expected: compilation fails because `LocalContextScope.explanation` and `SettingsView.automaticTemplateHelp` do not exist.

- [ ] **Step 3: Add exhaustive presentation metadata**

Update `LocalContextScope.displayName` to the five approved names and add an exhaustive `explanation` switch using the exact strings from Step 1. Do not alter the enum declaration or raw values.

- [ ] **Step 4: Split and clarify the Settings sections**

Replace `Section("Local context")` with `Section("On-device text context")` containing `Picker("Text context", ...)`, the selected scope's `explanation`, the unchanged conditional permission warning, and the always-visible privacy note from the spec. Attach the approved section, picker, and supplemental option `.help` strings.

Add a separate `Section("Automatic template selection")` containing `Toggle("Automatically choose template", ...)`, the approved inline description, and the exact section/toggle help strings. Expose the toggle help as `static let automaticTemplateHelp` for focused copy testing.

- [ ] **Step 5: Run the focused suite and verify GREEN**

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalContextPresentationTests`.

Expected: all focused tests pass.

- [ ] **Step 6: Run regression verification**

Run `make test`, `make app`, and `git diff --check`.

Expected: the full suite passes, the release app builds and signs, and diff check produces no output.

- [ ] **Step 7: Manually inspect Settings**

Confirm each picker choice updates the visible description; permission warnings remain below it; the privacy note is always visible; the two sections fit the minimum Settings size; and hover help appears where AppKit supports it.

- [ ] **Step 8: Commit**

Stage only the two source files and focused test, then commit with `Clarify context settings copy`.
