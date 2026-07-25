import CoreMedia
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
        .automationFolderUnavailable,
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

    // MARK: - Finding 2 (round 1) / Finding 1 (round 2): folder-scoped file authorization via bookmark

    @Test func noAutomationFolderConfiguredRefusesEveryFile() {
        #expect(throws: AutomationError.automationFolderNotConfigured) {
            _ = try AutomationFileAuthorization.authorize(URL(fileURLWithPath: "/tmp/clip.wav"), automationFolderBookmark: nil)
        }
    }

    @Test func fileInsideTheConfiguredFolderIsAuthorized() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        let bookmark = try Self.bookmark(for: root)

        let authorized = try AutomationFileAuthorization.authorize(file, automationFolderBookmark: bookmark)
        #expect(authorized.url.path == file.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(authorized.folder.path == root.resolvingSymlinksInPath().standardizedFileURL.path)
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
        let bookmark = try Self.bookmark(for: root)

        #expect(throws: AutomationError.fileNotAuthorized) {
            _ = try AutomationFileAuthorization.authorize(file, automationFolderBookmark: bookmark)
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
        let bookmark = try Self.bookmark(for: root)

        #expect(throws: AutomationError.fileNotAuthorized) {
            _ = try AutomationFileAuthorization.authorize(escapingSymlink, automationFolderBookmark: bookmark)
        }
    }

    // MARK: - Codex round-2 Finding 1: a bookmark whose directory was replaced/removed is rejected,
    // never silently re-resolved against whatever now sits at the old path. This is the concrete
    // defeat the raw-path design allowed: a caller (or `defaults write`) could repoint the folder
    // string at an attacker-chosen directory. A bookmark instead follows the real filesystem
    // object; when that object is gone, resolution/existence must fail closed.

    @Test func bookmarkForARemovedDirectoryIsRejected() throws {
        let root = try Self.makeTempDirectory()
        let bookmark = try Self.bookmark(for: root)
        try FileManager.default.removeItem(at: root)

        #expect(throws: AutomationError.automationFolderUnavailable) {
            _ = try AutomationFileAuthorization.authorize(
                URL(fileURLWithPath: "/tmp/clip.wav"), automationFolderBookmark: bookmark
            )
        }
    }

    @Test func bookmarkWhoseDirectoryWasReplacedByAFileIsRejected() throws {
        let root = try Self.makeTempDirectory()
        let bookmark = try Self.bookmark(for: root)
        try FileManager.default.removeItem(at: root)
        // Same path, a different real object (a file, not a directory) — simulates the folder
        // being replaced out from under the saved bookmark.
        FileManager.default.createFile(atPath: root.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: AutomationError.automationFolderUnavailable) {
            _ = try AutomationFileAuthorization.authorize(
                URL(fileURLWithPath: "/tmp/clip.wav"), automationFolderBookmark: bookmark
            )
        }
    }

    @Test func garbageBookmarkDataIsRejected() {
        #expect(throws: AutomationError.automationFolderUnavailable) {
            _ = try AutomationFileAuthorization.authorize(
                URL(fileURLWithPath: "/tmp/clip.wav"), automationFolderBookmark: Data([0x01, 0x02, 0x03])
            )
        }
    }

    // MARK: - Codex round-2 Finding 2: file descriptors pinned with O_NOFOLLOW, fstat, staging copy

    @Test func stagingCopiesTheAuthorizedFileAndCleansUpAfter() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.wav")
        let contents = Data("audio-bytes".utf8)
        FileManager.default.createFile(atPath: file.path, contents: contents)

        let staged = try AutomationMediaStaging.stage(
            canonicalFolder: root, canonicalFile: file, maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
        )
        #expect(staged.url != file)
        #expect(try Data(contentsOf: staged.url) == contents)
        staged.cleanup()
        #expect(!FileManager.default.fileExists(atPath: staged.url.path))
    }

    @Test func stagingRefusesANonRegularFile() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notAFile = root.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(at: notAFile, withIntermediateDirectories: false)

        #expect(throws: AutomationError.unsupportedMediaFile) {
            _ = try AutomationMediaStaging.stage(
                canonicalFolder: root, canonicalFile: notAFile, maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
            )
        }
    }

    @Test func stagingRefusesASymlinkEvenWhenItsTargetIsARegularFile() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realFile = root.appendingPathComponent("real.wav")
        FileManager.default.createFile(atPath: realFile.path, contents: Data("x".utf8))
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        // Codex round-2 Finding 2's exact attack: the symlink is planted AFTER the authorization
        // check already ran against `link`'s canonical (resolved) path — `stage` must still refuse
        // it because it opens `link.wav` itself with O_NOFOLLOW, never following to `real.wav`.
        #expect(throws: AutomationError.unsupportedMediaFile) {
            _ = try AutomationMediaStaging.stage(
                canonicalFolder: root, canonicalFile: link, maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
            )
        }
    }

    @Test func stagingRefusesAnOversizedFile() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.wav")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 1024)
        try handle.close()

        #expect(throws: AutomationError.mediaTooLarge) {
            _ = try AutomationMediaStaging.stage(canonicalFolder: root, canonicalFile: big, maximumBytes: 100)
        }
    }

    // MARK: - Codex round-2 Finding 5: duration validation fails CLOSED, never open

    @Test func mediaDurationCapIsAPureComparison() {
        #expect(AutomationMediaGuard.isDurationWithinLimit(seconds: 60))
        #expect(!AutomationMediaGuard.isDurationWithinLimit(seconds: AutomationMediaGuard.maximumMediaDurationSeconds + 1))
    }

    @Test func durationValidationRejectsAFailedLoad() async {
        struct LoadFailure: Error {}
        await #expect(throws: AutomationError.mediaTooLarge) {
            try await AutomationMediaGuard.validateDuration { throw LoadFailure() }
        }
    }

    @Test func durationValidationRejectsIndefiniteDuration() async {
        // `CMTime.indefinite.seconds` is NaN — the exact "playable fragmented file with indefinite
        // duration" case the finding describes bypassing the guard.
        await #expect(throws: AutomationError.mediaTooLarge) {
            try await AutomationMediaGuard.validateDuration { .indefinite }
        }
    }

    @Test func durationValidationRejectsInfiniteDuration() async {
        await #expect(throws: AutomationError.mediaTooLarge) {
            try await AutomationMediaGuard.validateDuration { .positiveInfinity }
        }
    }

    @Test func durationValidationRejectsAnInvalidCMTime() async {
        await #expect(throws: AutomationError.mediaTooLarge) {
            try await AutomationMediaGuard.validateDuration { .invalid }
        }
    }

    @Test func durationValidationAcceptsAValidWithinLimitDuration() async throws {
        try await AutomationMediaGuard.validateDuration { CMTime(seconds: 60, preferredTimescale: 600) }
    }

    @Test func durationValidationRejectsAValidButOverLimitDuration() async {
        await #expect(throws: AutomationError.mediaTooLarge) {
            try await AutomationMediaGuard.validateDuration {
                CMTime(seconds: AutomationMediaGuard.maximumMediaDurationSeconds + 1, preferredTimescale: 600)
            }
        }
    }

    private static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
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

    // MARK: - Codex round-2 Finding 4: `transcribe` gets its own single-in-flight slot

    @Test func onlyOneTranscribeMayBeInFlightAtATime() {
        // Ensure a clean slate regardless of test ordering.
        AutomationConcurrencyGate.endTranscribe()

        #expect(AutomationConcurrencyGate.beginTranscribe() == true)
        #expect(AutomationConcurrencyGate.beginTranscribe() == false, "a second concurrent call must be rejected as busy")
        AutomationConcurrencyGate.endTranscribe()
        #expect(AutomationConcurrencyGate.beginTranscribe() == true, "the slot must be free again once the first call ends")
        AutomationConcurrencyGate.endTranscribe()
    }

    @Test func transcribeAndCleanUpSlotsAreIndependent() {
        AutomationConcurrencyGate.endCleanUp()
        AutomationConcurrencyGate.endTranscribe()

        #expect(AutomationConcurrencyGate.beginCleanUp() == true)
        #expect(AutomationConcurrencyGate.beginTranscribe() == true, "transcribe must not be blocked by an in-flight clean up")
        AutomationConcurrencyGate.endCleanUp()
        AutomationConcurrencyGate.endTranscribe()
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

    // MARK: - Codex round-2 Finding 1: the bookmark (the real authority) persists independently

    @Test func automationFolderBookmarkIsUnsetByDefault() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.automationFolderBookmark == nil)
    }

    @Test func automationFolderBookmarkPersistsAcrossReload() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let bookmark = Data([0x01, 0x02, 0x03])

        settings.automationFolderBookmark = bookmark

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.automationFolderBookmark == bookmark)
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
