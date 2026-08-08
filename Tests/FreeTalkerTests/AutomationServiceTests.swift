import Foundation
import Testing
@testable import FreeTalker

/// BRAINSTORM_AUTOMATION_SURFACE.md's required runnable checks for the pure logic: the consent
/// gate refusing when disabled and template-name resolution including the unknown-name error.
/// Deliberately excludes anything that needs Shortcuts, `osascript`, or a live AppleEvent dispatch
/// — those are exercised manually (see PLAN.md/BRAINSTORM's verification notes).
@Suite("Automation surface pure logic")
@MainActor
struct AutomationServiceTests {
    // MARK: - Consent gate defaults (off on first run, per BRAINSTORM_AUTOMATION_SURFACE.md)

    @Test func automationIsDisabledByDefault() throws {
        let suite = TestDefaults.freshSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.automationEnabled == false)
    }

    @Test func automationEnabledPersistsAcrossReload() throws {
        let suite = TestDefaults.freshSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.automationEnabled = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.automationEnabled == true)
    }
    // MARK: - Consent gate

    @Test func gateThrowsAutomationDisabledWhenOff() {
        #expect(throws: AutomationError.automationDisabled) {
            try AutomationGate.checkEnabled(false)
        }
    }

    @Test func gateAllowsWhenOn() throws {
        try AutomationGate.checkEnabled(true)
    }

    // MARK: - Template-name resolution

    private static let templates = [
        Template(id: "clean-dictation", name: "Clean Dictation", prompt: "Clean it up."),
        Template(id: "custom-1", name: "Meeting Notes", prompt: "Summarize as notes."),
        // A deliberate name collision — template names aren't enforced unique in this app.
        Template(id: "custom-2", name: "Meeting Notes", prompt: "A different, later-created duplicate."),
    ]

    @Test func resolvesTemplateByExactName() {
        let resolved = TemplateStore.resolveTemplate(named: "Clean Dictation", in: Self.templates)
        #expect(resolved == .found(Self.templates[0]))
    }

    @Test func unknownTemplateNameResolvesToNotFoundNeverASubstitutedDefault() {
        #expect(TemplateStore.resolveTemplate(named: "Nonexistent Template", in: Self.templates) == .notFound)
    }

    @Test func nameLookupIsCaseSensitive() {
        // No silent case-insensitive fallback — an exact-name contract is the least surprising
        // one, and matches "unknown name is an error, never a silently substituted default."
        #expect(TemplateStore.resolveTemplate(named: "clean dictation", in: Self.templates) == .notFound)
    }

    // Codex round-6 finding: a name matching more than one stored Template must never be resolved
    // by silently picking one (the previous "first match wins" behavior) — the caller has no way
    // to know which of the colliding Templates actually ran, and the winner can silently change
    // across an app update (see `TemplateStore.resolveTemplate`'s doc comment and the whitespace-
    // migration regression test below). Refusing as `.ambiguous` is the only honest outcome for an
    // exact-name contract that genuinely cannot disambiguate two identically-named Templates.
    @Test func duplicateTemplateNamesReportAmbiguousInsteadOfSilentlyResolvingEither() {
        let resolved = TemplateStore.resolveTemplate(named: "Meeting Notes", in: Self.templates)
        #expect(resolved == .ambiguous)
    }

    // MARK: - Codex round-9 finding (LOW): a stored Template name is canonicalized (trimmed) so
    // an exact-name lookup can never resolve to the wrong Template because of invisible
    // surrounding whitespace — see `TemplateStore.canonicalizeTemplateName`/`upsert`.

    @Test func templateNameWhitespaceIsCanonicalizedOnStoreSoItCannotDistinguishTwoTemplates() throws {
        let store = try makeIsolatedTemplateStore()

        try store.upsert(Template(id: "padded", name: " Report ", prompt: "Padded name."))

        // The invariant itself: revert the trim in `upsert` and this is the first thing to fail —
        // the stored name would still carry its surrounding whitespace.
        let stored = try #require(store.template(id: "padded"))
        #expect(stored.name == "Report")

        // End-to-end: `CleanUpTextCommand` trims its caller-supplied "using template" argument
        // before ever calling `resolveTemplate` (CleanUpTextCommand.swift). Because storage is
        // canonicalized the same way, a caller asking for "Report" resolves to this Template —
        // there is no separate, distinct " Report " Template left on disk that a different
        // caller could have been asking for instead.
        if case .found(let match) = TemplateStore.resolveTemplate(named: "Report", in: store.templates) {
            #expect(match.id == "padded")
        } else {
            Issue.record("expected .found(padded)")
        }
        #expect(TemplateStore.resolveTemplate(named: " Report ", in: store.templates) == .notFound)
    }

    // MARK: - Codex round-6 finding: the regression this whole fix exists for

    // THE REGRESSION: stored order `[(" Report ", prompt A), ("Report", prompt B)]`. Before this
    // fix, the caller's trimmed "Report" argument resolved to the first-match Template after
    // `trimmingTemplateNames` canonicalized BOTH stored names to "Report" (preserving storage
    // order) — silently running prompt A where, pre-migration, the same call used to resolve
    // prompt B. Nothing was dropped or corrupted; a user's automation just silently ran the wrong
    // Template. This test builds that exact on-disk pre-migration state (two Templates whose
    // stored names differ only by surrounding whitespace) and drives it through the real
    // `TemplateStore.init` migration path — the same way a real pre-existing install produces it —
    // then asserts the lookup now refuses to guess.
    @Test func whitespaceCanonicalizationMigrationNeverMakesAnAmbiguousLookupSilentlyPickAWinner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-ambiguous-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        let promptA = Template(id: "template-a", name: " Report ", prompt: "Prompt A")
        let promptB = Template(id: "template-b", name: "Report", prompt: "Prompt B")
        let encoder = JSONEncoder()
        try encoder.encode([promptA, promptB]).write(to: fileURL)
        let defaults = try #require(UserDefaults(suiteName: TestDefaults.freshSuiteName()))

        // The one-time `trimmingTemplateNames` migration runs here, on init, exactly as it does
        // on a real launch against a real pre-existing `templates.json`.
        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        // Both stored names now read "Report" — the migration itself is correct and untouched by
        // this fix (Codex confirmed it's one-to-one and idempotent).
        #expect(store.template(id: "template-a")?.name == "Report")
        #expect(store.template(id: "template-b")?.name == "Report")

        // The regression: this lookup must error as ambiguous, never silently resolve to either
        // Template's prompt.
        #expect(TemplateStore.resolveTemplate(named: "Report", in: store.templates) == .ambiguous)

        // The fix must not block the one way a user actually resolves this: the Templates UI
        // (Settings → Templates) lists both colliding Templates by id via `store.templates`
        // regardless of the name collision, and can rename either one through the same `upsert`
        // path it always used — nothing here required touching `upsert`, `delete`, or the
        // published `templates` list.
        // Other unrelated one-time migrations (e.g. seeding the Prompt Engineer built-ins into a
        // non-empty pre-existing library) also fire on this same `init` — irrelevant to this fix,
        // so only assert the two Templates under test are both still present, not an exact set.
        #expect(Set(store.templates.map(\.id)).isSuperset(of: ["template-a", "template-b"]))
        var renamed = try #require(store.template(id: "template-a"))
        renamed.name = "Report (Original)"
        try store.upsert(renamed)

        // Listing still shows both, now under distinct names — renaming neither deleted nor
        // merged either Template.
        #expect(store.template(id: "template-a")?.name == "Report (Original)")
        #expect(store.template(id: "template-b")?.name == "Report")

        // And the rename is exactly how a user fixes the ambiguity going forward: each name now
        // resolves unambiguously to the Template that actually owns it.
        #expect(TemplateStore.resolveTemplate(named: "Report (Original)", in: store.templates) == .found(renamed))
        if case .found(let match) = TemplateStore.resolveTemplate(named: "Report", in: store.templates) {
            #expect(match.id == "template-b")
        } else {
            Issue.record("expected .found(template-b)")
        }
    }

    private func makeIsolatedTemplateStore() throws -> TemplateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-template-canonicalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        let defaults = try #require(UserDefaults(suiteName: TestDefaults.freshSuiteName()))
        return TemplateStore(fileURL: fileURL, defaults: defaults)
    }

    // MARK: - Error descriptions surface distinct, branchable AppleScript error codes

    private static let allErrors: [AutomationError] = [
        .automationDisabled, .unknownTemplate("x"), .ambiguousTemplateName("x"), .modelUnavailable,
        .processingFailed, .invalidInput("x"), .emptyText, .textTooLarge, .busy,
    ]

    @Test func everyAutomationErrorHasADistinctAppleScriptErrorCode() {
        let codes = Set(Self.allErrors.map(\.appleScriptErrorCode))
        #expect(codes.count == Self.allErrors.count)
        for error in Self.allErrors {
            #expect(error.errorDescription != nil && !(error.errorDescription!.isEmpty))
        }
    }

    // MARK: - Finding 6: sanitized errors carry no absolute filesystem paths

    @Test func noAutomationErrorDescriptionLeaksAnAbsolutePath() {
        for error in Self.allErrors {
            let description = error.errorDescription ?? ""
            #expect(!description.contains("/Users"))
            #expect(!description.contains("/private/"))
        }
    }

    @Test func processingFailureSanitizesAnUnderlyingErrorCarryingAPath() {
        struct FakePipelineError: Error, CustomStringConvertible {
            var description: String { "missing model at /Users/someone/Library/Application Support/FreeTalker/Models/tiny.mlmodelc" }
        }
        let sanitized = AutomationErrorSanitizer.processingFailure(FakePipelineError(), context: "test")
        #expect(sanitized == .processingFailed)
        #expect(!(sanitized.errorDescription ?? "").contains("/Users"))
    }

    // MARK: - Finding 1: `clean up` never has a cloud path — on-device processor failures map to distinct, sanitized errors, never a cloud fallback

    @Test func onDeviceModelUnavailableMapsToModelUnavailable() {
        #expect(AutomationErrorSanitizer.processorFailure(AppleFMProcessor.FMError.unavailable) == .modelUnavailable)
    }

    @Test func translationUnsupportedIsUnreachableFromCleanUpAndFallsThroughToTheGenericSanitizedError() {
        // AutomationService.cleanUpText always passes `languagePolicy: .preserveSource` — the only
        // condition that ever makes AppleFMProcessor throw `.translationUnsupported` — and this
        // sdef exposes no language parameter, so no AppleEvent input can reach this branch. No
        // AutomationError case is reserved for it; it falls through to the same sanitized mapping
        // as any other unexpected FMError case.
        #expect(AutomationErrorSanitizer.processorFailure(AppleFMProcessor.FMError.translationUnsupported) == .processingFailed)
    }

    // MARK: - Finding 3: text/template bounds and single in-flight enforcement

    @Test func emptyTextIsRefused() {
        #expect(throws: AutomationError.emptyText) {
            try AutomationTextValidation.validateCleanUpText("")
        }
        #expect(throws: AutomationError.emptyText) {
            try AutomationTextValidation.validateCleanUpText("   \n\t  ")
        }
    }

    @Test func oversizedTextIsRefused() {
        let oversized = String(repeating: "a", count: AutomationTextValidation.maximumCleanUpTextBytes + 1)
        #expect(throws: AutomationError.textTooLarge) {
            try AutomationTextValidation.validateCleanUpText(oversized)
        }
    }

    @Test func textAtTheLimitIsAccepted() throws {
        let atLimit = String(repeating: "a", count: AutomationTextValidation.maximumCleanUpTextBytes)
        try AutomationTextValidation.validateCleanUpText(atLimit)
    }

    // MARK: - Codex round-2 Finding 3: raw byte count is checked BEFORE trimming

    @Test func oversizedWhitespaceOnlyTextIsRejectedForSizeNotEmptiness() {
        // If `trimmingCharacters(in:)` ran first (the round-1 order), this text — all whitespace,
        // over the byte cap — would trim down to empty and report `.emptyText`. Checking the raw
        // byte count first must report `.textTooLarge` instead, proving the size check runs
        // before the (expensive, scan-and-allocate) trim ever executes.
        let oversizedWhitespace = String(repeating: " ", count: AutomationTextValidation.maximumCleanUpTextBytes + 1)
        #expect(throws: AutomationError.textTooLarge) {
            try AutomationTextValidation.validateCleanUpText(oversizedWhitespace)
        }
    }

    @Test func oversizedTemplateNameIsRefused() {
        let oversized = String(repeating: "a", count: BackupBundleBounds.maxTemplateNameBytes + 1)
        #expect(throws: AutomationError.invalidInput("The template name is too long.")) {
            try AutomationTextValidation.validateTemplateName(oversized)
        }
    }

    @Test func onlyOneCleanUpMayBeInFlightAtATime() {
        // Ensure a clean slate regardless of test ordering.
        AutomationConcurrencyGate.endCleanUp()

        #expect(AutomationConcurrencyGate.beginCleanUp() == true)
        #expect(AutomationConcurrencyGate.beginCleanUp() == false, "a second concurrent call must be rejected as busy")
        AutomationConcurrencyGate.endCleanUp()
        #expect(AutomationConcurrencyGate.beginCleanUp() == true, "the slot must be free again once the first call ends")
        AutomationConcurrencyGate.endCleanUp()
    }
}
