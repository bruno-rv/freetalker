# Vocabulary Editor Affordance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the empty vocabulary editor visibly editable while preserving
its existing persistence and normalization behavior.

**Architecture:** A file-local SwiftUI field wrapper layers approved guidance
over the existing binding and applies semantic macOS field chrome. A small
internal presentation contract makes the exact copy and sizing testable without
coupling tests to SwiftUI's private view structure.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit semantic colors, Swift Testing,
macOS 26.

## Global constraints

- Modify only vocabulary presentation and accessibility metadata.
- Preserve `AppSettings.vocabularyText` storage and normalization unchanged.
- Use semantic macOS colors in light and dark appearances.
- Use exact placeholder copy **One term or phrase per line**.
- Use exact examples **OpenAI** and **ScreenCaptureKit**.
- Use exact VoiceOver label **Vocabulary terms**.
- Do not add a package dependency.

---

### Task 1: Add visible vocabulary field chrome

**Files:**

- Modify: `Sources/FreeTalker/UI/SettingsView.swift:884-901`
- Create: `Tests/FreeTalkerTests/VocabularySettingsTests.swift`

**Interfaces:**

- Consumes: `Binding<String>` from `settings.vocabularyText`.
- Produces: `VocabularyEditorPresentation` and file-local
  `VocabularyEditorField`.

- [ ] **Step 1: Write failing presentation and characterization tests**

Create `Tests/FreeTalkerTests/VocabularySettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import FreeTalker

@Suite("Vocabulary settings")
struct VocabularySettingsTests {
    @Test("editor presentation uses approved guidance")
    func approvedPresentation() {
        #expect(VocabularyEditorPresentation.placeholder ==
                "One term or phrase per line")
        #expect(VocabularyEditorPresentation.examples == [
            "OpenAI", "ScreenCaptureKit"
        ])
        #expect(VocabularyEditorPresentation.accessibilityLabel ==
                "Vocabulary terms")
        #expect(VocabularyEditorPresentation.minimumHeight == 100)
        #expect(VocabularyEditorPresentation.cornerRadius == 7)
    }

    @Test("raw vocabulary persists while normalized terms trim blanks")
    func persistenceAndNormalization() throws {
        let suite = "VocabularySettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let raw = " OpenAI \n\nScreenCaptureKit"

        let settings = AppSettings(defaults: defaults)
        settings.vocabularyText = raw

        #expect(defaults.string(forKey: "vocabularyText") == raw)
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.vocabularyText == raw)
        #expect(reloaded.vocabulary == ["OpenAI", "ScreenCaptureKit"])
    }
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter VocabularySettingsTests
```

Expected: compilation fails because `VocabularyEditorPresentation` does not
exist.

- [ ] **Step 3: Add the presentation contract and field wrapper**

Add beside the vocabulary settings section in `SettingsView.swift`:

```swift
enum VocabularyEditorPresentation {
    static let placeholder = "One term or phrase per line"
    static let examples = ["OpenAI", "ScreenCaptureKit"]
    static let accessibilityLabel = "Vocabulary terms"
    static let minimumHeight: CGFloat = 100
    static let cornerRadius: CGFloat = 7
}

private struct VocabularyEditorField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(VocabularyEditorPresentation.placeholder)
                    ForEach(VocabularyEditorPresentation.examples,
                            id: \.self) { example in
                        Text(example)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.clear)
                .focused($isFocused)
                .accessibilityLabel(
                    VocabularyEditorPresentation.accessibilityLabel
                )
        }
        .frame(minHeight: VocabularyEditorPresentation.minimumHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(
            cornerRadius: VocabularyEditorPresentation.cornerRadius
        ))
        .overlay {
            RoundedRectangle(
                cornerRadius: VocabularyEditorPresentation.cornerRadius
            )
            .stroke(
                isFocused ? Color.accentColor :
                    Color(nsColor: .separatorColor),
                lineWidth: isFocused ? 2 : 1
            )
        }
    }
}
```

Replace the bare `TextEditor` and its frame with:

```swift
VocabularyEditorField(text: $settings.vocabularyText)
```

Do not edit `AppSettings`, `SettingsChrome`, or transcription code.

- [ ] **Step 4: Run focused and full tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter VocabularySettingsTests
make test
git diff --check
```

Expected: focused and full suites pass, and `git diff --check` reports no
errors.

- [ ] **Step 5: Build and perform the visual-accessibility smoke matrix**

```bash
make app
open FreeTalker.app
```

Verify empty and populated content in light and dark appearances. Verify Tab
focus, neutral-to-accent focus border, VoiceOver announcing only
**Vocabulary terms**, placeholder disappearance after the first character, and
raw text persistence after relaunch.

- [ ] **Step 6: Commit the focused change**

```bash
git add Sources/FreeTalker/UI/SettingsView.swift \
  Tests/FreeTalkerTests/VocabularySettingsTests.swift
git commit -m "fix: clarify vocabulary editor affordance"
```
