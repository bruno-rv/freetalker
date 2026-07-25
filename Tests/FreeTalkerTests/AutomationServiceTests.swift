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

    private static let allErrors: [AutomationError] = [
        .automationDisabled, .unsupportedFileType, .unknownTemplate("x"),
        .modelUnavailable, .cloudCapabilityUnavailable, .processingFailed, .cancelled,
        .invalidInput("x"), .automationFolderNotConfigured, .fileNotAuthorized,
        .unsupportedMediaFile, .mediaTooLarge, .emptyText, .textTooLarge, .busy, .timedOut,
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

    // MARK: - Finding 2: folder-scoped file authorization

    @Test func noAutomationFolderConfiguredRefusesEveryFile() {
        #expect(throws: AutomationError.automationFolderNotConfigured) {
            _ = try AutomationFileAuthorization.authorize(URL(fileURLWithPath: "/tmp/clip.wav"), automationFolderPath: nil)
        }
        #expect(throws: AutomationError.automationFolderNotConfigured) {
            _ = try AutomationFileAuthorization.authorize(URL(fileURLWithPath: "/tmp/clip.wav"), automationFolderPath: "")
        }
    }

    @Test func fileInsideTheConfiguredFolderIsAuthorized() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        let authorized = try AutomationFileAuthorization.authorize(file, automationFolderPath: root.path)
        #expect(authorized.path == file.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func fileOutsideTheConfiguredFolderIsRefused() throws {
        let root = try Self.makeTempDirectory()
        let outside = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let file = outside.appendingPathComponent("clip.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        #expect(throws: AutomationError.fileNotAuthorized) {
            _ = try AutomationFileAuthorization.authorize(file, automationFolderPath: root.path)
        }
    }

    @Test func symlinkInsideTheFolderPointingOutsideItIsRefused() throws {
        let root = try Self.makeTempDirectory()
        let outside = try Self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let realFile = outside.appendingPathComponent("secret.wav")
        FileManager.default.createFile(atPath: realFile.path, contents: Data("x".utf8))
        let escapingSymlink = root.appendingPathComponent("escape.wav")
        try FileManager.default.createSymbolicLink(at: escapingSymlink, withDestinationURL: realFile)

        #expect(throws: AutomationError.fileNotAuthorized) {
            _ = try AutomationFileAuthorization.authorize(escapingSymlink, automationFolderPath: root.path)
        }
    }

    // MARK: - Finding 4: non-regular-file and oversized-file refusal

    @Test func nonRegularFileIsRefused() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notAFile = root.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(at: notAFile, withIntermediateDirectories: false)

        #expect(throws: AutomationError.unsupportedMediaFile) {
            try AutomationMediaGuard.requireRegularFile(at: notAFile)
        }
    }

    @Test func symlinkFileIsRefusedEvenWhenExtensionAndTargetAreValid() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realFile = root.appendingPathComponent("real.wav")
        FileManager.default.createFile(atPath: realFile.path, contents: Data("x".utf8))
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        #expect(throws: AutomationError.unsupportedMediaFile) {
            try AutomationMediaGuard.requireRegularFile(at: link)
        }
    }

    @Test func oversizedRegularFileIsRefused() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.wav")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AutomationMediaGuard.maximumSourceFileBytes) + 1)
        try handle.close()

        #expect(throws: AutomationError.mediaTooLarge) {
            try AutomationMediaGuard.requireRegularFile(at: big)
        }
    }

    @Test func mediaDurationCapIsAPureComparison() {
        #expect(!AutomationMediaGuard.exceedsMaximumDuration(seconds: 60))
        #expect(AutomationMediaGuard.exceedsMaximumDuration(seconds: AutomationMediaGuard.maximumMediaDurationSeconds + 1))
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutomationServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    // MARK: - Finding 2 (Settings): the automation folder setting persists and defaults to unset

    @Test func automationFolderPathIsUnsetByDefault() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.automationFolderPath == nil)
    }

    @Test func automationFolderPathPersistsAcrossReload() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.automationFolderPath = "/tmp/some-folder"

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.automationFolderPath == "/tmp/some-folder")
    }

    // MARK: - Finding 2: the bridged direct-parameter resolver only accepts a real file reference

    @Test func resolveFileURLAcceptsURLAndNSURL() {
        #expect(TranscribeFileCommand.resolveFileURL(URL(fileURLWithPath: "/tmp/clip.wav")) != nil)
        #expect(TranscribeFileCommand.resolveFileURL(NSURL(fileURLWithPath: "/tmp/clip.wav")) != nil)
    }

    @Test func resolveFileURLRejectsABarePathString() {
        #expect(TranscribeFileCommand.resolveFileURL("/tmp/clip.wav") == nil)
    }
}
