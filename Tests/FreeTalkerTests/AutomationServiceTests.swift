import CoreMedia
import Darwin
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
            canonicalFolder: root, canonicalFile: file,
            folderIdentity: try AutomationFileAuthorization.FileIdentity.of(root),
            maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
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
                canonicalFolder: root, canonicalFile: notAFile,
                folderIdentity: try AutomationFileAuthorization.FileIdentity.of(root),
                maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
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
                canonicalFolder: root, canonicalFile: link,
                folderIdentity: try AutomationFileAuthorization.FileIdentity.of(root),
                maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
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
            _ = try AutomationMediaStaging.stage(
                canonicalFolder: root, canonicalFile: big,
                folderIdentity: try AutomationFileAuthorization.FileIdentity.of(root),
                maximumBytes: 100
            )
        }
    }

    // MARK: - Codex round-3 Finding 3: a FIFO is refused WITHOUT hanging, off-main-actor staging
    // is genuinely cancellable, and a same-user directory exchange is caught (additional finding)

    @Test func stagingRefusesAFIFOWithoutHanging() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("hang.wav")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let identity = try AutomationFileAuthorization.FileIdentity.of(root)

        // Before the fix, `open()` on a FIFO opened for reading with no writer blocks forever —
        // this would hang the whole test run (and the CI job with it) instead of failing fast.
        // Racing it against a short deadline turns "hangs forever" into a reportable failure
        // rather than a silent timeout of the whole suite.
        let outcome = try await withThrowingTaskGroup(of: AutomationError?.self) { group in
            group.addTask {
                do {
                    _ = try AutomationMediaStaging.stage(
                        canonicalFolder: root, canonicalFile: fifo, folderIdentity: identity,
                        maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
                    )
                    return nil
                } catch let error as AutomationError {
                    return error
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return .timedOut
            }
            let first = try await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        #expect(outcome == .unsupportedMediaFile, "a FIFO must be rejected as non-regular — O_NONBLOCK must keep the open from ever blocking on a missing writer")
    }

    @Test func stagingCopyIsCancellableInsteadOfAlwaysRunningToCompletion() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.wav")
        // Large enough that reading it fully takes measurably longer than a single chunk — proves
        // the copy loop's `Task.isCancelled` check (Codex round-3 Finding 3) actually interrupts a
        // staging copy instead of always running the whole synchronous copy to completion once
        // started, which is what let a slow/hostile copy defeat the 2-hour deadline race entirely.
        let contents = Data(repeating: 0x42, count: 64 * 1024 * 1024)
        FileManager.default.createFile(atPath: file.path, contents: contents)
        let identity = try AutomationFileAuthorization.FileIdentity.of(root)

        let task = Task<AutomationMediaStaging.StagedFile, Error> {
            try AutomationMediaStaging.stage(
                canonicalFolder: root, canonicalFile: file, folderIdentity: identity,
                maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
            )
        }
        task.cancel()
        let outcome = await task.result
        guard case .failure(let error) = outcome else {
            Issue.record("a cancelled staging copy must fail, not run to completion")
            return
        }
        #expect(error as? AutomationError == .timedOut)
    }

    // MARK: - Codex round-3 additional finding: the bookmark-resolved folder is reopened by
    // pathname; a same-user process that swaps the real directory object at that path is caught.

    @Test func directoryExchangeAfterAuthorizationIsRejectedByIdentityCheck() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clip.wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        // Simulates `authorize()`'s identity check having captured `root`'s ORIGINAL identity,
        // then a same-user process deleting and recreating the directory at that same path before
        // `openPinned` reopens it — a different real object, same pathname.
        let staleIdentity = try AutomationFileAuthorization.FileIdentity.of(root)
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        #expect(throws: AutomationError.automationFolderUnavailable) {
            _ = try AutomationMediaStaging.stage(
                canonicalFolder: root, canonicalFile: file, folderIdentity: staleIdentity,
                maximumBytes: AutomationMediaGuard.maximumSourceFileBytes
            )
        }
    }

    // MARK: - Codex round-3 Finding 6: staging lifetime is tied to the durable job, not a lexical
    // `defer` — an orphan left by a crash before that job existed (or after it was deleted) is
    // purged by `purgeOrphans`.

    @Test func purgeOrphansDeletesUnreferencedStagingFilesButKeepsReferencedOnes() throws {
        let stagingDirectory = AutomationMediaStaging.stagingDirectoryURL
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let kept = stagingDirectory.appendingPathComponent("AutomationServiceTests-keep-\(UUID().uuidString).wav")
        let orphan = stagingDirectory.appendingPathComponent("AutomationServiceTests-orphan-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: kept.path, contents: Data("keep".utf8))
        FileManager.default.createFile(atPath: orphan.path, contents: Data("orphan".utf8))
        defer {
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.removeItem(at: orphan)
        }

        AutomationMediaStaging.purgeOrphans(keeping: [kept.path])

        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func removeIfStagedNeverTouchesAFileOutsideTheStagingDirectory() throws {
        let outside = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let userFile = outside.appendingPathComponent("not-staged.wav")
        FileManager.default.createFile(atPath: userFile.path, contents: Data("mine".utf8))

        AutomationMediaStaging.removeIfStaged(atPath: userFile.path)

        #expect(FileManager.default.fileExists(atPath: userFile.path))
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

    // MARK: - Codex round-3 additional finding: the gate's flags are lock-protected — concurrent
    // callers (as `beginTranscribe()` on the main thread vs. `endTranscribe()` off the main actor
    // now genuinely can be, per Finding 3) must never both observe the slot as free at once.

    @Test func beginTranscribeIsExclusiveUnderConcurrentContention() async {
        AutomationConcurrencyGate.endTranscribe()
        defer { AutomationConcurrencyGate.endTranscribe() }

        let grants = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask { AutomationConcurrencyGate.beginTranscribe() }
            }
            var grantedCount = 0
            for await granted in group where granted { grantedCount += 1 }
            return grantedCount
        }
        // Exactly one of the 200 concurrent callers may claim the single slot — an unsynchronized
        // check-then-set could let more than one briefly observe it as free.
        #expect(grants == 1)
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

    // MARK: - Codex round-2 Finding 1 / round-3 Finding 1: the bookmark (the real authority)
    // persists independently, through an injectable Keychain-backed store — never the real system
    // Keychain in a test, and never `UserDefaults` (see the forged-bookmark test below).

    @Test func automationFolderBookmarkIsUnsetByDefault() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults, secretStore: InMemorySecretStore())

        #expect(settings.automationFolderBookmark == nil)
    }

    @Test func automationFolderBookmarkPersistsAcrossReloadThroughTheSameSecretStore() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secretStore = InMemorySecretStore()
        let settings = AppSettings(defaults: defaults, secretStore: secretStore)
        let bookmark = Data([0x01, 0x02, 0x03])

        settings.automationFolderBookmark = bookmark

        let reloaded = AppSettings(defaults: defaults, secretStore: secretStore)
        #expect(reloaded.automationFolderBookmark == bookmark)
    }

    @Test func clearingTheBookmarkRemovesItFromTheSecretStore() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secretStore = InMemorySecretStore()
        let settings = AppSettings(defaults: defaults, secretStore: secretStore)
        settings.automationFolderBookmark = Data([0x01, 0x02, 0x03])

        settings.automationFolderBookmark = nil

        #expect(settings.automationFolderBookmark == nil)
        #expect(secretStore.values[Keychain.Account.automationFolderBookmark] == nil)
    }

    // MARK: - Codex round-3 Finding 1: a bookmark forged directly into `UserDefaults` (the exact
    // round-2 `defaults write` attack, re-encoded as bookmark data instead of a path string) is
    // never read for authorization — only the Keychain-backed store is.

    @Test func forgedUserDefaultsBookmarkIsIgnoredNeverTrusted() throws {
        let suite = "AutomationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Simulates a same-user process running `defaults write org.freetalker.app
        // automationFolderBookmark <bookmark for />` BEFORE FreeTalker ever launches.
        let forged = try Self.bookmark(for: URL(fileURLWithPath: "/"))
        defaults.set(forged, forKey: "automationFolderBookmark")

        let settings = AppSettings(defaults: defaults, secretStore: InMemorySecretStore())

        #expect(settings.automationFolderBookmark == nil)
    }

    private final class InMemorySecretStore: SecretStore {
        var values: [String: String]

        init(values: [String: String] = [:]) { self.values = values }

        func get(account: String) -> String? { values[account] }
        @discardableResult func set(_ value: String, account: String) -> Bool {
            values[account] = value
            return true
        }
        @discardableResult func delete(account: String) -> Bool {
            values.removeValue(forKey: account)
            return true
        }
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
