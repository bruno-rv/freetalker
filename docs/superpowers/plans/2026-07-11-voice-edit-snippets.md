# Voice Editing and Snippets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local voice-driven edits and snippet expansion with mandatory confirmation previews.

**Architecture:** A MainActor selection service captures/revalidates AX targets, `VoiceEditCoordinator` owns memory-only preview state, and SQLite-backed `SnippetStore` resolves exact normalized triggers before local generation.

**Tech Stack:** ApplicationServices, FoundationModels, SQLite, SwiftUI, CGEvent hotkeys.

## Global Constraints

- No edit or snippet modifies text before confirmation.
- Selected text, instruction, and preview are memory-only.
- Secure fields are rejected.
- Confirm revalidates app, focused element, selected range, and selected-text hash.

---

### Task 1: Selection capture/revalidation and third hotkey

**Files:**
- Create: `Sources/FreeTalker/Workflows/VoiceEdit/SelectionSnapshot.swift`
- Create: `Sources/FreeTalker/Core/SelectionAccess.swift`
- Modify: `Sources/FreeTalker/Core/HotKeyManager.swift`
- Modify: `Sources/FreeTalker/Core/HotKeySpec.swift`
- Modify: `Sources/FreeTalker/Settings/AppSettings.swift`
- Test: `Tests/FreeTalkerTests/VoiceEditTargetTests.swift`

- [ ] **Step 1: Write failing tests** for selection fingerprints, secure roles, stale selection, three-way hotkey collision, and synchronous event dispatch.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement Sendable snapshot and named hotkey actions:**

```swift
@MainActor struct SelectionSnapshot { let target: InsertionTarget; let range: NSRange; let text: String; let fingerprint: Data }
@MainActor protocol SelectionAccessing { func capture() throws -> SelectionSnapshot; func replace(_ snapshot: SelectionSnapshot, with text: String) throws }
```

- [ ] **Step 4: Run focused tests GREEN.**
- [ ] **Step 5: Commit `feat: add safe voice-edit targeting`.**

### Task 2: Snippet persistence and trigger matching

**Files:**
- Create: `Sources/FreeTalker/Models/Snippet.swift`
- Create: `Sources/FreeTalker/Storage/SnippetStore.swift`
- Test: `Tests/FreeTalkerTests/SnippetStoreTests.swift`

- [ ] **Step 1: Write failing CRUD/normalization/duplicate/ambiguity tests.**
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement exact normalization:** Unicode case-fold, trim punctuation at boundaries, collapse whitespace, reject empty and duplicate normalized triggers.
- [ ] **Step 4: Run focused tests GREEN.**
- [ ] **Step 5: Commit `feat: add local voice snippets`.**

### Task 3: Local edit service and preview coordinator

**Files:**
- Create: `Sources/FreeTalker/Workflows/VoiceEdit/LocalEditService.swift`
- Create: `Sources/FreeTalker/Workflows/VoiceEdit/VoiceEditCoordinator.swift`
- Create: `Sources/FreeTalker/UI/VoiceEditPreviewView.swift`
- Test: `Tests/FreeTalkerTests/VoiceEditCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests** for no-selection rejection, snippet-before-generation, ambiguous chooser, preview-only behavior, cancel, stale confirm, copy fallback, and local-generation failure.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement memory-only preview:**

```swift
@MainActor final class VoiceEditCoordinator: ObservableObject {
    @Published private(set) var preview: VoiceEditPreview?
    func begin() async
    func confirm() throws
    func cancel()
    func copyResult()
}
```

Use a new Foundation Models session per edit; no cloud processor path.
- [ ] **Step 4: Run focused tests and release build GREEN.**
- [ ] **Step 5: Commit `feat: preview local voice edits`.**

### Task 4: Settings and app lifecycle integration

**Files:**
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Create: `Sources/FreeTalker/UI/SnippetsSettingsView.swift`
- Modify: `README.md`
- Test: `Tests/FreeTalkerTests/VoiceEditPresentationTests.swift`

- [ ] **Step 1: Write failing presentation tests** for hotkey states, snippet editor validation, preview accessibility, and local-only disclaimer.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Wire hotkey callback, preview window, snippet editor, keyboard/VoiceOver labels, and target-drift error.**
- [ ] **Step 4: Run `swift test && make app && git diff --check`.**
- [ ] **Step 5: Commit `feat: ship voice editing and snippets`.**
