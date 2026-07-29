# Settings Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the tab-based settings window with a Raycast-inspired native SwiftUI settings shell and add selective contextual help without changing settings behavior.

**Architecture:** A presentational settings-chrome layer owns sidebar navigation, page/card surfaces, standard rows, and accessible help popovers. `GeneralSettingsView` retains all existing state, bindings, dialogs, hotkey capture, keychain, and network actions; it only groups its current sections into private card builders. Templates and Snippets retain their split-editor implementations inside the new chrome.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Package Manager, macOS SF Symbols, XCTest.

## Global Constraints

- Preserve persisted setting keys, bindings, actions, dialogs, and existing accessibility labels.
- Use SF Symbols; do not add raster assets or force a global app appearance.
- Use `questionmark.circle` only for non-obvious settings; privacy disclosures, errors, disabled-state explanations, and important status text stay visibly present.
- Keep `GeneralSettingsView` as the state owner; helper views are presentational only.
- Preserve the Templates and Snippets `HSplitView` editor workflows.
- Do not add a window-mode setting or new product behavior.

---

## File Structure

- Create `Sources/FreeTalker/UI/SettingsChrome.swift`: reusable SwiftUI navigation, page, card, row, and help-popover views.
- Modify `Sources/FreeTalker/UI/SettingsView.swift:84-1057`: replace top-level tabs, retain General state/callback ownership, regroup General content, and wrap Templates.
- Modify `Sources/FreeTalker/UI/SnippetsSettingsView.swift:63-207`: wrap the existing snippet split view without changing storage calls or dialogs.
- No production model or persistence changes.
- No new automated test file: the refactor is presentation-only and the repository has no SwiftUI snapshot harness. Existing behavior tests and a clean release build protect retained binding and copy behavior.

### Task 1: Establish a tested baseline

**Files:**
- Test: `Tests/FreeTalkerTests/LocalContextPresentationTests.swift`
- Test: `Tests/FreeTalkerTests/OutputLanguageSettingsTests.swift`
- Test: `Tests/FreeTalkerTests/ScreenRecordingPermissionTests.swift`
- Test: `Tests/FreeTalkerTests/VoiceEditTargetTests.swift`

**Interfaces:**
- Consumes: existing settings presentation and persistence behavior.
- Produces: baseline evidence before a presentation-only refactor.

- [ ] **Step 1: Run the focused settings behavior tests before modifying production code.**

```bash
make test TEST_FILTER='LocalContextPresentationTests|OutputLanguageSettingsTests|ScreenRecordingPermissionTests|VoiceEditTargetTests'
```

Expected: all selected tests pass. If the Makefile does not accept `TEST_FILTER`, run `make test` and record the environment limitation if the machine cannot run the Xcode test suite.

- [ ] **Step 2: Run the release build before modifying production code.**

```bash
make build
```

Expected: Swift package release build exits 0.

### Task 2: Add reusable settings chrome and the sidebar shell

**Files:**
- Create: `Sources/FreeTalker/UI/SettingsChrome.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift:84-113`

**Interfaces:**
- Consumes: `SettingsDestination` selected at the root settings view.
- Produces: `SettingsDestination`, `SettingsSidebar`, `SettingsPage`, `SettingsCard`, `SettingsRow`, and `SettingsHelpButton`.

- [ ] **Step 1: Add presentation-only helpers using generic `@ViewBuilder` closures, never `AnyView`.**

```swift
enum SettingsDestination: String, CaseIterable, Identifiable {
    case general, templates, snippets
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .templates: "Templates"
        case .snippets: "Snippets"
        }
    }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .templates: "text.badge.checkmark"
        case .snippets: "text.quote"
        }
    }
}

struct SettingsHelpButton: View {
    let title: String
    let message: String
    @State private var isPresented = false
    var body: some View {
        Button { isPresented.toggle() } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.plain)
            .help(message)
            .accessibilityLabel("Help: \(title)")
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                Text(message).padding().frame(maxWidth: 280, alignment: .leading)
            }
    }
}
```

Implement `SettingsSidebar`, `SettingsPage`, `SettingsCard`, and `SettingsRow`. `SettingsPage` owns scrolling and heading; `SettingsCard` owns its adaptive rounded surface/dividers; `SettingsRow` aligns label, optional detail/help, and trailing control.

- [ ] **Step 2: Replace only the root `TabView` with the sidebar and a `SettingsDestination` switch.**

```swift
@State private var selection: SettingsDestination = .general

var body: some View {
    HStack(spacing: 0) {
        SettingsSidebar(selection: $selection)
        Divider()
        switch selection {
        case .general: GeneralSettingsView()
        case .templates: TemplatesSettingsView()
        case .snippets: SnippetsSettingsView()
        }
    }
    .frame(minWidth: 780, minHeight: 560)
}
```

Retain the existing coordinator observation and window configuration; do not touch `App.swift`.

- [ ] **Step 3: Build and commit the shell.**

```bash
make build
git add Sources/FreeTalker/UI/SettingsChrome.swift Sources/FreeTalker/UI/SettingsView.swift
git commit -m "feat: add settings sidebar shell"
```

Expected: release build exits 0 before committing.

### Task 3: Group General settings into cards and add selective help

**Files:**
- Modify: `Sources/FreeTalker/UI/SettingsView.swift:191-957`
- Test: `Tests/FreeTalkerTests/LocalContextPresentationTests.swift`
- Test: `Tests/FreeTalkerTests/OutputLanguageSettingsTests.swift`
- Test: `Tests/FreeTalkerTests/VoiceEditTargetTests.swift`

**Interfaces:**
- Consumes: existing `GeneralSettingsView` state/actions, `SettingsCard`, `SettingsRow`, and `SettingsHelpButton`.
- Produces: identical General bindings/actions grouped into card sections.

- [ ] **Step 1: Keep all state and lifecycle modifiers on `GeneralSettingsView`, replacing only its `Form` body with `SettingsPage`.**

```swift
var body: some View {
    SettingsPage(title: "General", subtitle: "Recording, transcription, and language preferences") {
        permissionsCard
        contextAndAutomationCard
        recordingCard
        floatingControlsCard
        storageCard
        audioAndTranscriptionCard
        cloudProcessingCard
    }
    // Retain every existing alert, sheet, task, and lifecycle modifier here.
}
```

- [ ] **Step 2: Move existing rows into seven private `@ViewBuilder` card properties without changing bindings or closures.**

```swift
@ViewBuilder private var contextAndAutomationCard: some View {
    SettingsCard(title: "Context and automation", subtitle: "How FreeTalker selects and applies dictation context") {
        localContextSection
        automaticTemplateSection
        appRulesSection
    }
}
```

Create `permissionsCard`, `contextAndAutomationCard`, `recordingCard`, `floatingControlsCard`, `storageCard`, `audioAndTranscriptionCard`, and `cloudProcessingCard`. Extract the existing local-context, automatic-template, and app-rules content into the named private builders shown above. Keep complex hotkey, speech-model, network-test, vocabulary, and app-rule controls specialized; do not force them through `SettingsRow`.

- [ ] **Step 3: Add help only to local context, automatic template selection, redo-last/voice-edit hotkeys, hands-free mode, recovery/media retention, live-preview cloud disclosure, and app-rule priority.**

```swift
SettingsHelpButton(
    title: "Automatically choose template",
    message: SettingsView.automaticTemplateHelp
)
```

Retain `CloudPrivacyDisclosure.settings`, permission guidance, capture errors, disabled-state help, model-specific help, and vocabulary warnings visibly in the card.

- [ ] **Step 4: Run behavior tests, build, and commit the General refactor.**

```bash
make test TEST_FILTER='LocalContextPresentationTests|OutputLanguageSettingsTests|ScreenRecordingPermissionTests|VoiceEditTargetTests|FloatingControlsSettingsTests|NoiseSuppressionSettingsTests'
make build
git add Sources/FreeTalker/UI/SettingsView.swift
git commit -m "feat: group general settings into cards"
```

Expected: all available selected tests and the release build pass before committing. If filtering is unsupported, run `make test` and record its result.

### Task 4: Apply matching page chrome to Templates and Snippets

**Files:**
- Modify: `Sources/FreeTalker/UI/SettingsView.swift:960-1057`
- Modify: `Sources/FreeTalker/UI/SnippetsSettingsView.swift:63-207`

**Interfaces:**
- Consumes: `SettingsPage` and existing `TemplatesSettingsView`, `TemplateEditor`, and `SnippetsSettingsView` state.
- Produces: matching page surfaces that preserve editor behavior.

- [ ] **Step 1: Wrap Templates and Snippets in `SettingsPage` while retaining their current `HSplitView` implementation.**

```swift
SettingsPage(title: "Templates", subtitle: "Create and refine reusable dictation formats") {
    HSplitView {
        templateList
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
        TemplateEditor(template: $selectedTemplate)
    }
}

SettingsPage(title: "Snippets", subtitle: "Manage reusable text snippets") {
    HSplitView {
        snippetList
        snippetEditor
    }
}
```

Do not change the template list width constraint, `TemplateEditor` API, snippet storage calls, trigger validation, confirmation dialog, or accessibility labels. Add no help that replaces existing validation/error text.

- [ ] **Step 2: Run all available tests and build the release package.**

```bash
make test
make build
```

Expected: the suite and build exit 0. If `make test` cannot run because full Xcode is unavailable, report the exact limitation and preserve successful build evidence.

- [ ] **Step 3: Manually inspect navigation, scrolling, help, resizing, and both split editors; then commit.**

Verify sidebar switching, readable long cards, working controls, concise help popovers, keyboard focus on help controls, intact editor splits, and no clipping after resize.

```bash
git add Sources/FreeTalker/UI/SettingsView.swift Sources/FreeTalker/UI/SnippetsSettingsView.swift
git commit -m "feat: unify settings page chrome"
```

## Plan Self-Review

- Spec coverage: Tasks 2–4 cover sidebar navigation, adaptive cards, preserved editors, SF Symbols, selective help, and accessibility. Tasks 1 and 4 verify retained behavior and package integrity.
- Placeholder scan: no deferred work, unspecified paths, or generic testing directives remain.
- Type consistency: every page uses `SettingsPage`; card/row helpers are generic views; `SettingsDestination` is the root selection type; `SettingsHelpButton` always receives `title` and `message`.
