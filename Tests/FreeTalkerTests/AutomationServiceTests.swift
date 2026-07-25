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
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.automationEnabled == false)
    }

    @Test func automationEnabledPersistsAcrossReload() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
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
        #expect(resolved?.id == "clean-dictation")
    }

    @Test func unknownTemplateNameResolvesToNilNeverASubstitutedDefault() {
        #expect(TemplateStore.resolveTemplate(named: "Nonexistent Template", in: Self.templates) == nil)
    }

    @Test func nameLookupIsCaseSensitive() {
        // No silent case-insensitive fallback — an exact-name contract is the least surprising
        // one, and matches "unknown name is an error, never a silently substituted default."
        #expect(TemplateStore.resolveTemplate(named: "clean dictation", in: Self.templates) == nil)
    }

    @Test func duplicateTemplateNamesResolveDeterministicallyToTheFirstMatch() {
        let resolved = TemplateStore.resolveTemplate(named: "Meeting Notes", in: Self.templates)
        #expect(resolved?.id == "custom-1")
    }

    // MARK: - Error descriptions surface distinct, branchable AppleScript error codes

    private static let allErrors: [AutomationError] = [
        .automationDisabled, .unknownTemplate("x"), .modelUnavailable, .cloudCapabilityUnavailable,
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

    @Test func translationUnsupportedMapsToCloudCapabilityUnavailableNeverASilentFallback() {
        #expect(AutomationErrorSanitizer.processorFailure(AppleFMProcessor.FMError.translationUnsupported) == .cloudCapabilityUnavailable)
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
