# Output translation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add API-only output translation for live dictation and existing
Library entries while keeping spoken-language recognition, destinations,
original text, and privacy boundaries intact.

**Architecture:** Represent output language as a typed policy that cannot enter
speech-recognition APIs. Reuse one eligible cloud snapshot for a one-pass
template-and-translation request, carry that immutable policy through explicit
recording destinations, and retain source text for user-directed recovery.
Persist non-destructive Library variants through a transactional migration and
unique parent-language key.

**Tech stack:** Swift 6.2, SwiftUI, AppKit, SQLite, Swift Package Manager,
Swift Testing, UserDefaults, Keychain, and the existing cloud LLM transport.

## Global constraints

- Target macOS 26 and add no dependency.
- Spoken language remains Automatic, English, or Portuguese and is the only
  value that may enter WhisperKit or Cloud STT language parameters.
- Output choices are Same as spoken, English, Portuguese, Mandarin Chinese,
  Hindi, Spanish, Standard Arabic, French, and German, in that order.
- Default output is Same as spoken; invalid persisted values normalize to it.
- Launcher and HUD overrides apply to one recording and clear on every terminal
  path without changing the persisted default.
- Named translation requires canonical `CloudLLMEligibility.eligible` and one
  captured `CloudLLMSettingsSnapshot` per request.
- Named translation never falls back to Apple Foundation Models, another
  provider, or silent source-text insertion.
- Fixed preserve/target-language directives are mutually exclusive and cannot
  be overridden by user templates.
- Translation failure retains source text and offers Retry translation or
  explicit Insert source text through the captured safe destination.
- Library variants never replace the original and remain unique by parent and
  target language.
- Live, Scratchpad, and Library UI use the same API requirement wording,
  tooltip, and accessibility help.
- Never persist API keys, request headers, settings snapshots, or full prompts.

---

## File map

Create:

- `Sources/FreeTalker/Models/OutputLanguage.swift`: stable output identifiers,
  display names, and typed preserve/translate policy.
- `Sources/FreeTalker/Models/CloudFeatureAvailability.swift`: shared canonical
  API availability presentation.
- `Sources/FreeTalker/Core/RecordingOutputSelection.swift`: pending/current
  one-recording override state machine.
- `Sources/FreeTalker/Workflows/Translation/TranslationService.swift`: API-only
  one-pass formatting and translation.
- `Sources/FreeTalker/Workflows/Translation/PendingTranslationRecovery.swift`:
  retained source, immutable request context, retry, and source insertion.
- `Sources/FreeTalker/Models/DictationTranslationVariant.swift`: Library
  translation value model.
- `Sources/FreeTalker/UI/TranslationControls.swift`: reusable labeled output
  selector and disabled help.
- `Sources/FreeTalker/UI/LibraryTranslationController.swift`: Library async
  translation, confirmation, cancellation, and persistence state.

Modify:

- `Sources/FreeTalker/Settings/AppSettings.swift`
- `Sources/FreeTalker/UI/SettingsView.swift`
- `Sources/FreeTalker/Engines/PostProcessor.swift`
- `Sources/FreeTalker/Engines/CloudLLMProcessor.swift`
- `Sources/FreeTalker/Engines/AppleFMProcessor.swift`
- `Sources/FreeTalker/UI/FloatingControls/FloatingControlsController.swift`
- `Sources/FreeTalker/UI/FloatingControls/FloatingControlsView.swift`
- `Sources/FreeTalker/UI/HUDPanel.swift`
- `Sources/FreeTalker/App.swift`
- `Sources/FreeTalker/AppCoordinator.swift`
- `Sources/FreeTalker/Models/Dictation.swift`
- `Sources/FreeTalker/Storage/DatabaseMigrations.swift`
- `Sources/FreeTalker/Storage/Database.swift`
- `Sources/FreeTalker/Storage/LibraryStore.swift`
- `Sources/FreeTalker/UI/LibraryView.swift`
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift`
- `Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift`
- `README.md`

---

### Task 1: Add output-language and shared API-availability models

**Files:**
- Create: `Sources/FreeTalker/Models/OutputLanguage.swift`
- Create: `Sources/FreeTalker/Models/CloudFeatureAvailability.swift`
- Test: `Tests/FreeTalkerTests/OutputLanguageTests.swift`
- Test: `Tests/FreeTalkerTests/CloudFeatureAvailabilityTests.swift`

**Interfaces:**
- Produces: `OutputLanguage`, `TranslationTarget`,
  `OutputProcessingPolicy`, and `CloudFeatureAvailability`.
- Consumes: `CloudLLMEligibility` and `LLMProviderKind` only.

- [ ] **Step 1: Add failing model tests**

Test exact order, raw values, display/prompt names, German, invalid fallback,
the impossibility of translating to Same as spoken, provider-specific missing
key guidance, invalid configuration guidance, and tooltip/help equality.

```swift
@Test func outputLanguagesHaveStableOrder() {
    #expect(OutputLanguage.allCases == [
        .sameAsSpoken, .english, .portuguese, .mandarinChinese,
        .hindi, .spanish, .standardArabic, .french, .german,
    ])
}

@Test func sameAsSpokenBuildsOnlyPreservePolicy() {
    #expect(OutputLanguage.sameAsSpoken.processingPolicy == .preserveSource)
    #expect(OutputLanguage.portuguese.processingPolicy ==
        .translate(to: .portuguese))
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'OutputLanguageTests|CloudFeatureAvailabilityTests'
```

Expected: compile failure because the new model types do not exist.

- [ ] **Step 3: Implement stable typed models**

```swift
enum OutputLanguage: String, CaseIterable, Codable, Sendable {
    case sameAsSpoken = "same"
    case english = "en"
    case portuguese = "pt"
    case mandarinChinese = "zh-Hans"
    case hindi = "hi"
    case spanish = "es"
    case standardArabic = "ar"
    case french = "fr"
    case german = "de"
}

enum TranslationTarget: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case portuguese = "pt"
    case mandarinChinese = "zh-Hans"
    case hindi = "hi"
    case spanish = "es"
    case standardArabic = "ar"
    case french = "fr"
    case german = "de"
}

enum OutputProcessingPolicy: Equatable, Sendable {
    case preserveSource
    case translate(to: TranslationTarget)
}
```

Guard `processingPolicy` so `.sameAsSpoken` can produce only preserve-source
behavior. Put shared settings-path copy in `CloudFeatureAvailability`; derive
it from canonical eligibility rather than URL/key inspection.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run Step 2. Expected: all model and shared-help tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeTalker/Models/OutputLanguage.swift \
  Sources/FreeTalker/Models/CloudFeatureAvailability.swift \
  Tests/FreeTalkerTests/OutputLanguageTests.swift \
  Tests/FreeTalkerTests/CloudFeatureAvailabilityTests.swift
git commit -m "Add output language models"
```

### Task 2: Persist the default and one-recording output override

**Files:**
- Create: `Sources/FreeTalker/Core/RecordingOutputSelection.swift`
- Modify: `Sources/FreeTalker/Settings/AppSettings.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Test: `Tests/FreeTalkerTests/OutputLanguageSettingsTests.swift`
- Test: `Tests/FreeTalkerTests/RecordingOutputSelectionTests.swift`

**Interfaces:**
- Consumes: `OutputLanguage`.
- Produces: `AppSettings.defaultOutputLanguage` and a pure
  `RecordingOutputSelection` reducer.

- [ ] **Step 1: Add failing persistence and reducer tests**

Cover default/round-trip/invalid stored values, independence from
`languagePin`, pre-record selection, current-recording changes, effective value,
and clearing on success, cancellation, transcription failure, translation
resolution, and explicit source insertion.

```swift
@Test func outputDefaultDoesNotChangeSpokenPin() async {
    let settings = await AppSettings(defaults: isolatedDefaults())
    await MainActor.run {
        settings.languagePin = "en"
        settings.defaultOutputLanguage = .german
    }
    #expect(await settings.languagePin == "en")
}
```

- [ ] **Step 2: Run tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'OutputLanguageSettingsTests|RecordingOutputSelectionTests'
```

- [ ] **Step 3: Implement setting and reducer**

Persist the enum raw value with unknown fallback to `.sameAsSpoken`. Add the
Settings picker under Floating controls with explicit **Default output
language** copy and shared API requirement help.

```swift
struct RecordingOutputSelection: Equatable, Sendable {
    private(set) var pending: OutputLanguage?
    private(set) var current: OutputLanguage?

    mutating func select(_ language: OutputLanguage, isRecording: Bool)
    mutating func start(default defaultLanguage: OutputLanguage)
        -> OutputLanguage
    mutating func resolveTerminal()
}
```

Copy the selected output into pending recovery before clearing global override
state on translation failure.

- [ ] **Step 4: Run focused and existing settings tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'OutputLanguage|RecordingOutput|FloatingControlsSettings'
```

Expected: all selected suites pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeTalker/Core/RecordingOutputSelection.swift \
  Sources/FreeTalker/Settings/AppSettings.swift \
  Sources/FreeTalker/UI/SettingsView.swift \
  Tests/FreeTalkerTests/OutputLanguageSettingsTests.swift \
  Tests/FreeTalkerTests/RecordingOutputSelectionTests.swift
git commit -m "Persist output language selection"
```

### Task 3: Add typed one-pass cloud translation processing

**Files:**
- Create: `Sources/FreeTalker/Workflows/Translation/TranslationService.swift`
- Modify: `Sources/FreeTalker/Engines/PostProcessor.swift`
- Modify: `Sources/FreeTalker/Engines/CloudLLMProcessor.swift`
- Modify: `Sources/FreeTalker/Engines/AppleFMProcessor.swift`
- Modify:
  `Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift`
- Test: `Tests/FreeTalkerTests/OutputTranslationPromptTests.swift`
- Test: `Tests/FreeTalkerTests/ScratchpadAIActionTests.swift`

**Interfaces:**
- Consumes: `OutputProcessingPolicy`, `CloudLLMSettingsSnapshot`, `Template`.
- Produces: `PostProcessingRequest`, `TranslationService`, and typed errors.

- [ ] **Step 1: Add failing policy and hostile-template tests**

Test every target prompt name, preserve/translate mutual exclusion, one API
call, same snapshot, output-only rule, hostile template unable to change target,
empty output, ineligible snapshot, transport error, and no Apple processor.

```swift
@Test func translationDirectiveCannotConflictWithPreserveDirective() {
    let instructions = buildProcessorInstructions(
        request: .init(transcript: "Hello", template: hostileTemplate,
                       appName: nil,
                       languagePolicy: .translate(to: .portuguese)),
        vocabulary: [])
    #expect(instructions.contains("Portuguese"))
    #expect(!instructions.contains("same language as the transcript"))
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'OutputTranslationPromptTests|ScratchpadAIActionTests'
```

- [ ] **Step 3: Introduce typed processor request**

```swift
struct PostProcessingRequest: Sendable {
    let transcript: String
    let template: Template
    let appName: String?
    let languagePolicy: OutputProcessingPolicy
}

protocol PostProcessor: Sendable {
    func process(_ request: PostProcessingRequest) async throws -> String
}
```

Keep Apple FM preserve-only: reject `.translate` before model invocation. Pass
`.preserveSource` explicitly from Scratchpad arbitrary text actions.

- [ ] **Step 4: Implement API-only translation service**

```swift
protocol Translating: Sendable {
    func process(source: String, template: Template,
                 policy: OutputProcessingPolicy,
                 snapshot: CloudLLMSettingsSnapshot) async throws -> String
}
```

Check canonical snapshot eligibility once, invoke `CloudLLMProcessor` once,
trim output, and throw `.emptyOutput` rather than returning source. Do not call
`resolveActiveProcessor` or Apple FM for named translation.

- [ ] **Step 5: Run processor and existing AI tests**

Run Step 2. Expected: all translation and Scratchpad AI suites pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/FreeTalker/Workflows/Translation/TranslationService.swift \
  Sources/FreeTalker/Engines/PostProcessor.swift \
  Sources/FreeTalker/Engines/CloudLLMProcessor.swift \
  Sources/FreeTalker/Engines/AppleFMProcessor.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift \
  Tests/FreeTalkerTests/OutputTranslationPromptTests.swift \
  Tests/FreeTalkerTests/ScratchpadAIActionTests.swift
git commit -m "Add API output translation service"
```

### Task 4: Add history metadata and Library translation storage

**Files:**
- Create: `Sources/FreeTalker/Models/DictationTranslationVariant.swift`
- Modify: `Sources/FreeTalker/Models/Dictation.swift`
- Modify: `Sources/FreeTalker/Storage/DatabaseMigrations.swift`
- Modify: `Sources/FreeTalker/Storage/Database.swift`
- Modify: `Sources/FreeTalker/Storage/LibraryStore.swift`
- Test: `Tests/FreeTalkerTests/DatabaseMigrationTests.swift`
- Test: `Tests/FreeTalkerTests/LibraryTranslationStoreTests.swift`

**Interfaces:**
- Consumes: stable `OutputLanguage.rawValue`.
- Produces: schema migration 10, source/output metadata, variant CRUD/upsert.

- [ ] **Step 1: Add failing v9-to-v10 and CRUD tests**

Cover direct Library database opening, existing row preservation, default
`same`, idempotent ledger migration, rollback, foreign keys, uniqueness,
atomic replace, deletion cascade, concurrent parent deletion, and originals
unchanged.

```swift
@Test func variantUpsertNeverChangesOriginal() async throws {
    let original = try await fixture.insertDictation(refined: "Hello")
    try await fixture.store.upsertTranslation(
        parentID: original.id, target: .portuguese, text: "Olá")
    #expect(try await fixture.store.dictation(id: original.id)?.refined ==
        "Hello")
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'DatabaseMigrationTests|LibraryTranslationStoreTests'
```

- [ ] **Step 3: Add migration 10 and enable the ledger for Library DB**

Migration 10 adds `requested_output_language TEXT NOT NULL DEFAULT 'same'`
to `dictations`, then creates:

```sql
CREATE TABLE dictation_translation_variants (
  parent_id TEXT NOT NULL,
  target_language TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  PRIMARY KEY (parent_id, target_language),
  FOREIGN KEY (parent_id) REFERENCES dictations(id) ON DELETE CASCADE
);
```

Make `Database` enable foreign keys and run `DatabaseMigrator` itself so direct
Library initialization cannot depend on another store's startup order.

- [ ] **Step 4: Replace positional record arguments with a value object**

Extend `Dictation` with typed source language and requested output language
while retaining the existing DB `language` column as source/STT semantics.
Update every SELECT projection/index together.

- [ ] **Step 5: Add transactional variant operations**

```swift
func translationVariants(parentID: UUID) throws
    -> [DictationTranslationVariant]
func upsertTranslation(parentID: UUID, target: TranslationTarget,
                       text: String) throws
func deleteTranslation(parentID: UUID, target: TranslationTarget) throws
```

Verify parent existence and upsert within one transaction. Never mutate raw or
refined original fields.

- [ ] **Step 6: Run migration/store tests and full database suites**

Run Step 2 plus existing Database and Library filters. Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/FreeTalker/Models/Dictation.swift \
  Sources/FreeTalker/Models/DictationTranslationVariant.swift \
  Sources/FreeTalker/Storage/DatabaseMigrations.swift \
  Sources/FreeTalker/Storage/Database.swift \
  Sources/FreeTalker/Storage/LibraryStore.swift \
  Tests/FreeTalkerTests/DatabaseMigrationTests.swift \
  Tests/FreeTalkerTests/LibraryTranslationStoreTests.swift
git commit -m "Store output metadata and translations"
```

### Task 5: Add launcher and HUD output controls

**Files:**
- Create: `Sources/FreeTalker/UI/TranslationControls.swift`
- Modify:
  `Sources/FreeTalker/UI/FloatingControls/FloatingControlsController.swift`
- Modify: `Sources/FreeTalker/UI/FloatingControls/FloatingControlsView.swift`
- Modify: `Sources/FreeTalker/UI/HUDPanel.swift`
- Modify: `Sources/FreeTalker/App.swift`
- Test: `Tests/FreeTalkerTests/FloatingControlsPresentationTests.swift`
- Test: `Tests/FreeTalkerTests/HUDWarningPresentationTests.swift`

**Interfaces:**
- Consumes: settings default, selection reducer, shared API availability.
- Produces: `Speak:` and `Output:` presentation plus output callbacks.

- [ ] **Step 1: Add failing presentation tests**

Assert explicit Speak/Output labels, all nine output choices/order, German,
launcher/HUD synchronization, pre-record/current override, disabled named
targets when API is ineligible, identical tooltip/accessibility help, and Same
as spoken remaining the neutral value.

- [ ] **Step 2: Run tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'FloatingControlsPresentationTests|HUDWarningPresentationTests'
```

- [ ] **Step 3: Add reusable output menu and callback wiring**

```swift
struct TranslationControlsState: Equatable {
    let effectiveOutput: OutputLanguage
    let override: OutputLanguage?
    let availability: CloudFeatureAvailability
}
```

Named choices are disabled without eligible API; use a non-disabled wrapper for
hover help. The spoken menu changes only `languagePin`/spoken one-shot. The
output menu changes only `RecordingOutputSelection`.

- [ ] **Step 4: Run presentation and window-policy regressions**

Run Step 2 plus `FloatingPanelPolicyTests`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FreeTalker/UI/TranslationControls.swift \
  Sources/FreeTalker/UI/FloatingControls \
  Sources/FreeTalker/UI/HUDPanel.swift Sources/FreeTalker/App.swift \
  Tests/FreeTalkerTests/FloatingControlsPresentationTests.swift \
  Tests/FreeTalkerTests/HUDWarningPresentationTests.swift
git commit -m "Add recording output controls"
```

### Task 6: Route translated output through external and Scratchpad pipelines

**Files:**
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Sources/FreeTalker/Core/RecordingDestination.swift`
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift`
- Test: `Tests/FreeTalkerTests/OutputTranslationPipelineTests.swift`
- Test: `Tests/FreeTalkerTests/RecordingDestinationTests.swift`
- Test: `Tests/FreeTalkerTests/ScratchpadRecordingTests.swift`

**Interfaces:**
- Consumes: output reducer, translation service, expanded history record.
- Produces: immutable per-recording processing context and translated delivery.

- [ ] **Step 1: Add failing pipeline tests**

Use engine/request spies to prove only spoken `en|pt|nil` reaches STT; output
never appears in WhisperKit/Cloud multipart language. Cover named translation,
Same behavior, captured snapshot, one cloud call, external insertion,
Scratchpad token replacement, focus/selection drift, Library metadata, and all
terminal override clears.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'OutputTranslationPipelineTests|RecordingDestinationTests|ScratchpadRecording'
```

- [ ] **Step 3: Split transcription from output processing**

```swift
struct RecordingProcessingContext {
    let destination: RecordingDestination
    let spokenLanguage: String?
    let outputLanguage: OutputLanguage
    let template: Template
    let cloudSnapshot: CloudLLMSettingsSnapshot?
}
```

Resolve and snapshot once at stop. Keep current preserve-source processor
behavior for Same as spoken. Named translation calls `TranslationService`
directly and never `resolveActiveProcessor`.

- [ ] **Step 4: Store source/output metadata without changing source semantics**

Replace the positional record callback with a result value carrying source
language, requested output, raw transcript, final output, engine, and template.
Keep `Dictation.language`/DB `language` as source/STT language.

- [ ] **Step 5: Run pipeline and existing context/privacy tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter \
  'OutputTranslation|RecordingDestination|ScratchpadRecording|AutomaticStyle'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter ContextRouting
```

Expected: all selected suites pass; external context semantics are unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/FreeTalker/AppCoordinator.swift \
  Sources/FreeTalker/Core/RecordingDestination.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift \
  Tests/FreeTalkerTests/OutputTranslationPipelineTests.swift \
  Tests/FreeTalkerTests/RecordingDestinationTests.swift \
  Tests/FreeTalkerTests/ScratchpadRecordingTests.swift
git commit -m "Route translated dictation output"
```

### Task 7: Add translation failure recovery

**Files:**
- Create:
  `Sources/FreeTalker/Workflows/Translation/PendingTranslationRecovery.swift`
- Modify: `Sources/FreeTalker/AppCoordinator.swift`
- Modify: `Sources/FreeTalker/UI/HUDPanel.swift`
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift`
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift`
- Test: `Tests/FreeTalkerTests/TranslationRecoveryTests.swift`

**Interfaces:**
- Consumes: raw transcript, immutable processing context, captured destination.
- Produces: session-scoped Retry translation and Insert source text actions.

- [ ] **Step 1: Add failing recovery tests**

Cover transport/empty/ineligible/cancel, no automatic insertion, raw retention,
fresh snapshot only on explicit retry, same target/template/output, explicit
source insertion, external target drift, Scratchpad token drift, late response
generation guards, and override already cleared globally.

- [ ] **Step 2: Run tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter TranslationRecoveryTests
```

- [ ] **Step 3: Implement pending recovery value and coordinator state**

```swift
struct PendingTranslationRecovery {
    let sourceTranscript: String
    let sourceLanguage: String?
    let outputLanguage: TranslationTarget
    let template: Template
    let destination: RecordingDestination
    let generation: UUID
}
```

Recovery is session-scoped because external AX targets/editor tokens cannot be
safely reconstructed after relaunch. Preserve source for copy/manual recovery
when the captured destination is no longer safe.

- [ ] **Step 4: Add explicit recovery UI**

HUD and Scratchpad show **Translation failed**, **Retry translation**, and
**Insert source text**. Label Raw as **Use source text** when translation is
selected; it is an explicit bypass, never an automatic fallback.

- [ ] **Step 5: Run focused recovery and destination tests**

Run Step 2 plus destination/Scratchpad suites. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add \
  Sources/FreeTalker/Workflows/Translation/PendingTranslationRecovery.swift \
  Sources/FreeTalker/AppCoordinator.swift Sources/FreeTalker/UI/HUDPanel.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift \
  Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift \
  Tests/FreeTalkerTests/TranslationRecoveryTests.swift
git commit -m "Add translation failure recovery"
```

### Task 8: Add non-destructive Library translation

**Files:**
- Create: `Sources/FreeTalker/UI/LibraryTranslationController.swift`
- Modify: `Sources/FreeTalker/UI/LibraryView.swift`
- Modify: `Sources/FreeTalker/Storage/LibraryStore.swift`
- Test: `Tests/FreeTalkerTests/LibraryTranslationTests.swift`

**Interfaces:**
- Consumes: `TranslationService`, variants store, shared API availability.
- Produces: refined-first/raw-fallback translation, variant selection,
  replacement confirmation, copy, and explicit insertion.

- [ ] **Step 1: Add failing controller/UI-state tests**

Cover refined-first source, raw fallback, every named target, API disabled help,
one snapshot, cancellation, empty/error, parent deletion, generation guards,
existing-target confirmation, atomic upsert, Original/variant selection, copy,
and insertion without original mutation.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter LibraryTranslationTests
```

- [ ] **Step 3: Implement controller with request generations**

```swift
@MainActor final class LibraryTranslationController: ObservableObject {
    func translate(entry: Dictation, to target: TranslationTarget)
    func confirmReplacement()
    func cancel()
}
```

Only matching generation may write or clear progress. Capture canonical
snapshot once. Parent existence and variant upsert remain transactional in the
store.

- [ ] **Step 4: Add Library detail controls**

Add **Translate...**, Original/variant picker, copy, retry/regenerate, confirmed
replace, and explicit insert. Use the shared disabled tooltip/accessibility
reason and visible cloud disclosure.

- [ ] **Step 5: Run Library, migration, and AI availability tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'LibraryTranslation|DatabaseMigration|CloudFeatureAvailability'
```

Expected: all selected suites pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/FreeTalker/UI/LibraryTranslationController.swift \
  Sources/FreeTalker/UI/LibraryView.swift \
  Sources/FreeTalker/Storage/LibraryStore.swift \
  Tests/FreeTalkerTests/LibraryTranslationTests.swift
git commit -m "Add Library translation variants"
```

### Task 9: Unify API dependency wording and privacy disclosure

**Files:**
- Modify:
  `Sources/FreeTalker/UI/Scratchpad/ScratchpadTransformationService.swift`
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadView.swift`
- Modify: `Sources/FreeTalker/UI/Scratchpad/ScratchpadWindowController.swift`
- Modify: `Sources/FreeTalker/UI/SettingsView.swift`
- Modify: `README.md`
- Test: `Tests/FreeTalkerTests/ScratchpadAIActionTests.swift`
- Test: `Tests/FreeTalkerTests/CloudFeatureAvailabilityTests.swift`

**Interfaces:**
- Consumes: shared API availability presentation.
- Produces: identical dependency wording and live update behavior everywhere.

- [ ] **Step 1: Add failing exact-copy and live-refresh tests**

Assert Scratchpad, launcher, HUD, and Library share the exact canonical settings
path/reason and refresh after provider/base/model/key changes without reopening.

- [ ] **Step 2: Run focused tests and confirm RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --filter 'ScratchpadAIActionTests|CloudFeatureAvailabilityTests'
```

- [ ] **Step 3: Replace feature-specific API wording**

Compose Scratchpad empty/in-flight/custom reasons ahead of the shared API
reason. Generalize the credentials-change notification without transmitting key
material; retain a compatibility alias only if a consumer still needs it.

- [ ] **Step 4: Document cloud boundaries**

README and Settings must state that live transcript, selected Scratchpad text,
or chosen Library text is sent only to the configured cloud endpoint. Do not
describe named translation as on-device.

- [ ] **Step 5: Run focused and Settings-copy tests**

Run Step 2 plus `LocalContextPresentationTests`. Expected: all pass and the
merged context copy remains unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/FreeTalker/UI/Scratchpad \
  Sources/FreeTalker/UI/SettingsView.swift README.md \
  Tests/FreeTalkerTests/ScratchpadAIActionTests.swift \
  Tests/FreeTalkerTests/CloudFeatureAvailabilityTests.swift
git commit -m "Clarify cloud feature requirements"
```

### Task 10: Verify the complete translation story

**Files:**
- Modify only if a verified defect is found: planned source/tests above.

**Interfaces:**
- Consumes: complete recording, recovery, Library, and shared-help flows.
- Produces: release evidence and a documented manual residual-risk matrix.

- [ ] **Step 1: Run complete automated tests**

```bash
make test
```

Expected: exit code 0 with no failed tests.

- [ ] **Step 2: Build and verify the release app**

```bash
make app
codesign --verify --deep --strict --verbose=2 FreeTalker.app
```

Expected: both commands exit 0.

- [ ] **Step 3: Run the manual language matrix**

With an eligible configured provider, verify English→Portuguese and reverse;
every named output including German; Same as spoken for EN/PT; launcher and HUD
overrides; external and Scratchpad success/cancel/fail/retry/source insertion;
Library translate/switch/regenerate/copy/insert/relaunch; settings change during
request; disabled tooltip/VoiceOver without API; and full-screen Spaces.

- [ ] **Step 4: Inspect final repository state**

```bash
git diff --check
git status --short
git diff --stat 7a54503...HEAD
```

Expected: no whitespace errors or unplanned source changes; preserve the three
pre-existing modified `.superpowers/sdd/task-*-report.md` files.

## Execution order

Tasks 1-2 establish types and state. Task 3 depends on Task 1 and can run in
parallel with Task 2 after the model commit. Task 4 depends on Task 1 and can
run in parallel with Task 3. Task 5 depends on Tasks 1-2. Task 6 depends on
Tasks 2-5. Task 7 depends on Tasks 3 and 6. Task 8 depends on Tasks 3-4. Task 9
depends on Tasks 1, 5, and 8. Task 10 runs last.

After every task, run a fresh task-scoped spec and quality review before
starting dependent work. Fix every Critical or Important finding and re-review.
After Task 10, run one whole-branch review against the approved specification.
