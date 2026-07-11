# Context-aware Automatic Styles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-controlled, memory-only local context and automatic style selection without exposing context to BYOK/cloud processors.

**Architecture:** `LocalContextProvider` captures bounded Accessibility data; `VisionOCRService` handles the explicit OCR scope; `AutomaticStyleClassifier` resolves a built-in profile. Only `AppleFMProcessor` accepts `LocalProcessingContext`.

**Tech Stack:** ApplicationServices, ScreenCaptureKit, Vision, FoundationModels, SwiftUI.

## Global Constraints

- Scope defaults to Off and captures only once when dictation stops.
- Caps: focused field 8,000 characters; active window/OCR 12,000 characters.
- Screenshots and context are memory-only and never reach cloud/BYOK requests.
- Manual App Rules always win.

---

### Task 1: Context scope and Accessibility capture

**Files:**
- Create: `Sources/FreeTalker/Models/LocalContextScope.swift`
- Create: `Sources/FreeTalker/Core/AccessibilityContext.swift`
- Create: `Sources/FreeTalker/Core/LocalContextProvider.swift`
- Modify: `Sources/FreeTalker/Settings/AppSettings.swift`
- Test: `Tests/FreeTalkerTests/LocalContextProviderTests.swift`

- [ ] **Step 1: Write fake-AX tests** for all scopes, caps, secure-field rejection, missing permission, and Off making zero provider calls.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement immutable Sendable snapshots:**

```swift
enum LocalContextScope: String, CaseIterable { case off, selectedText, focusedField, activeWindow, windowOCR }
struct LocalProcessingContext: Sendable { let appName: String?; let windowTitle: String?; let text: String }
@MainActor protocol LocalContextProvider { func capture(scope: LocalContextScope) -> ContextCapture }
```

AX objects never leave MainActor; return strings/identifiers only.
- [ ] **Step 4: Run focused tests GREEN.**
- [ ] **Step 5: Commit `feat: capture bounded local context`.**

### Task 2: Local OCR and style resolution

**Files:**
- Create: `Sources/FreeTalker/Core/VisionOCRService.swift`
- Create: `Sources/FreeTalker/Engines/AutomaticStyleClassifier.swift`
- Modify: `Sources/FreeTalker/Engines/PostProcessor.swift`
- Modify: `Sources/FreeTalker/Engines/AppleFMProcessor.swift`
- Test: `Tests/FreeTalkerTests/AutomaticStyleTests.swift`

- [ ] **Step 1: Write failing tests** for OCR cap/release, prompt delimiter injection resistance, four style classifications, manual-rule precedence, and cloud-context omission.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement:**

```swift
protocol VisionOCRServicing: Sendable { func recognizeText(in image: CGImage) async throws -> String }
enum AutomaticStyle: String { case email, conversational, document, technical }
struct AutomaticStyleClassifier { func classify(bundleID: String?, windowTitle: String?, context: String) -> AutomaticStyle }
```

Add a local-only AppleFM processing overload. Do not add context to `PostProcessor` or `CloudLLMProcessor` APIs.
- [ ] **Step 4: Run focused tests and `swift build` GREEN.**
- [ ] **Step 5: Commit `feat: add local automatic styles`.**

### Task 3: Coordinator and Settings integration

**Files:**
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Modify: `Sources/FreeTalker/UI/HUDPanel.swift`
- Modify: `README.md`
- Test: `Tests/FreeTalkerTests/ContextRoutingTests.swift`

- [ ] **Step 1: Write failing routing tests** for capture-at-stop, Off, BYOK omission, permission fallback, and precedence.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Capture AX snapshot synchronously before pipeline `await`; perform OCR/local processing in scoped task; release image immediately; add Settings scope/style controls and local-only disclaimer.**
- [ ] **Step 4: Run `swift test && make app && git diff --check`.**
- [ ] **Step 5: Commit `feat: wire private context-aware styles`.**

