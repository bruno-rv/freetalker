import Foundation
import Testing
@testable import FreeTalker

/// BRAINSTORM_AUTOMATION_SURFACE.md's required runnable checks for the pure logic: the consent
/// gate refusing when disabled, template-name resolution including the unknown-name error,
/// output-format selection, and file-type validation. Deliberately excludes anything that needs
/// Shortcuts, `osascript`, or a live AppleEvent dispatch — those are exercised manually (see
/// PLAN.md/BRAINSTORM's verification notes).
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

    // MARK: - Output-format selection

    @Test func parsesEachDocumentedFormatEnumerator() {
        #expect(AutomationTranscriptFormat.parse("plainText") == .plainText)
        #expect(AutomationTranscriptFormat.parse("markdown") == .markdown)
        #expect(AutomationTranscriptFormat.parse("srt") == .srt)
        #expect(AutomationTranscriptFormat.parse("vtt") == .vtt)
    }

    @Test func absentFormatDefaultsToPlainText() {
        #expect(AutomationTranscriptFormat.parse(nil) == .plainText)
    }

    // MARK: - File-type validation (same static function `transcribe` calls — no parallel check)

    @Test func fileTypeValidationAcceptsSupportedExtensions() {
        for name in ["clip.wav", "clip.m4a", "clip.mp3", "clip.mp4", "clip.mov"] {
            #expect(MediaImportService.isSupported(URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }

    @Test func fileTypeValidationRejectsUnsupportedExtensions() {
        for name in ["clip.txt", "clip.pdf", "clip"] {
            #expect(!MediaImportService.isSupported(URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }

    // MARK: - Error descriptions surface distinct, branchable AppleScript error codes

    @Test func everyAutomationErrorHasADistinctAppleScriptErrorCode() {
        let errors: [AutomationError] = [
            .automationDisabled, .unsupportedFileType, .unknownTemplate("x"),
            .pipelineFailed("x"), .cancelled, .invalidInput("x"),
        ]
        let codes = Set(errors.map(\.appleScriptErrorCode))
        #expect(codes.count == errors.count)
        for error in errors {
            #expect(error.errorDescription != nil && !(error.errorDescription!.isEmpty))
        }
    }
}
