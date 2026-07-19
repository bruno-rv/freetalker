import Foundation
import Testing
@testable import FreeTalker

/// F5 — Dictation Language Set. See PLAN.md's F5 verification list: normalizer, code-mapping
/// round-trip, pin/app-rule/one-shot coercion on set change, snapshot immutability.
@Suite("Dictation language set")
@MainActor
struct DictationLanguageTests {
    // MARK: - Normalizer (subset / min-1 / dedupe / invalid)

    @Test func normalizerKeepsOnlyCuratedCodes() {
        let normalized = AppSettings.normalizeDictationLanguages(["en", "xx", "fr", "yy"])
        #expect(normalized == ["en", "fr"])
    }

    @Test func normalizerDedupesPreservingFirstOccurrenceOrder() {
        let normalized = AppSettings.normalizeDictationLanguages(["fr", "en", "fr", "en", "de"])
        #expect(normalized == ["fr", "en", "de"])
    }

    @Test func normalizerIsCaseInsensitiveAndTrims() {
        let normalized = AppSettings.normalizeDictationLanguages([" EN ", "Fr"])
        #expect(normalized == ["en", "fr"])
    }

    @Test func normalizerFallsBackToDefaultWhenEmpty() {
        #expect(AppSettings.normalizeDictationLanguages([]) == AppSettings.defaultDictationLanguages)
    }

    @Test func normalizerFallsBackToDefaultWhenEveryCandidateIsInvalid() {
        #expect(AppSettings.normalizeDictationLanguages(["xx", "yy", "not-a-code"]) == AppSettings.defaultDictationLanguages)
    }

    @Test func normalizerAcceptsTheFullCuratedEight() {
        let all = DictationLanguage.allCases.map(\.rawValue)
        #expect(AppSettings.normalizeDictationLanguages(all) == all)
    }

    // MARK: - Code-mapping round-trip (STT code <-> display name <-> OutputLanguage/TranslationTarget)

    @Test(arguments: DictationLanguage.allCases)
    func everyDictationLanguageMapsToADistinctNonEmptyDisplayName(language: DictationLanguage) {
        #expect(!language.displayName.isEmpty)
    }

    @Test func displayNamesAreUniqueAcrossTheCuratedEight() {
        let names = Set(DictationLanguage.allCases.map(\.displayName))
        #expect(names.count == DictationLanguage.allCases.count)
    }

    @Test(arguments: DictationLanguage.allCases)
    func everyDictationLanguageHasACorrespondingOutputLanguage(language: DictationLanguage) {
        // STT code -> output code -> OutputLanguage is total: every curated language can be
        // selected as an output/translation target too (mandarinChinese's "zh" STT code maps to
        // OutputLanguage's "zh-Hans", not itself — the one place the two code spaces diverge).
        #expect(language.outputLanguage != .sameAsSpoken)
        #expect(OutputLanguage(rawValue: language.outputLanguageCode) == language.outputLanguage)
    }

    @Test func sttCodesNeverLeakIntoOutputLanguagePersistence() {
        // Mandarin Chinese is the one code that actually differs between the two spaces — an STT
        // "zh" must never be written back out as an output/translation language rawValue; it has
        // to go through the mapping to "zh-Hans" first.
        #expect(DictationLanguage.mandarinChinese.rawValue == "zh")
        #expect(DictationLanguage.mandarinChinese.outputLanguageCode == "zh-Hans")
        #expect(OutputLanguage(rawValue: "zh") == nil)
        #expect(DictationLanguage.mandarinChinese.translationTarget == .mandarinChinese)
    }

    @Test func presentationOptionsPreserveCuratedOrderAndDropUnknownCodes() {
        let options = DictationLanguagePresentation.options(for: ["ar", "en", "not-a-code", "de"])
        #expect(options.map(\.code) == ["en", "de", "ar"])
        #expect(options.map(\.label) == ["English", "German", "Standard Arabic"])
    }

    @Test func presentationDisplayNameFallsBackToRawCodeForUnknownInput() {
        #expect(DictationLanguagePresentation.displayName(for: "en") == "English")
        #expect(DictationLanguagePresentation.displayName(for: "xx") == "xx")
    }

    // MARK: - Pin / app-rule / one-shot coercion on set change

    @Test func settingsSetChangeCoercesInvalidPinToAuto() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.dictationLanguages = ["en", "pt", "es"]
        settings.languagePin = "es"
        #expect(settings.languagePin == "es")

        settings.dictationLanguages = ["en", "pt"]

        #expect(settings.languagePin == "auto")
    }

    @Test func settingsSetChangeLeavesAStillValidPinUntouched() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.dictationLanguages = ["en", "pt", "es"]
        settings.languagePin = "es"

        settings.dictationLanguages = ["es", "fr"]

        #expect(settings.languagePin == "es")
    }

    @Test func settingsSetChangeDeletesAppLanguageRuleEntriesPointingAtARemovedLanguage() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.dictationLanguages = ["en", "pt", "es"]
        settings.appLanguageRules = ["com.example.kept": "en", "com.example.removed": "es"]

        settings.dictationLanguages = ["en", "pt"]

        #expect(settings.appLanguageRules == ["com.example.kept": "en"])
    }

    @Test func appLanguageRulesSurvivingEntryIsUntouchedWhenItsCodeStaysConfigured() {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.dictationLanguages = ["en", "pt", "fr"]
        settings.appLanguageRules = ["com.example.a": "pt"]

        settings.dictationLanguages = ["en", "pt"]

        #expect(settings.appLanguageRules == ["com.example.a": "pt"])
    }

    @Test func normalizeLanguagePinRejectsCodesOutsideAllowedButAcceptsAuto() {
        #expect(AppSettings.normalizeLanguagePin("auto", allowed: ["en", "pt"]) == "auto")
        #expect(AppSettings.normalizeLanguagePin("pt", allowed: ["en", "pt"]) == "pt")
        #expect(AppSettings.normalizeLanguagePin("es", allowed: ["en", "pt"]) == "auto")
        #expect(AppSettings.normalizeLanguagePin("garbage", allowed: ["en", "pt"]) == "auto")
    }

    @Test func sanitizedLanguageRulesDropsOnlyEntriesOutsideAllowed() {
        let sanitized = AppSettings.sanitizedLanguageRules(
            ["a": "en", "b": "es", "c": "not-a-code"],
            allowed: ["en", "pt"]
        )
        #expect(sanitized == ["a": "en"])
    }

    @Test func coercedOneShotLanguageClearsOnlyWhenNoLongerAllowed() {
        #expect(AppCoordinator.coercedOneShotLanguage(current: "es", allowed: ["en", "pt"]) == nil)
        #expect(AppCoordinator.coercedOneShotLanguage(current: "en", allowed: ["en", "pt"]) == "en")
        #expect(AppCoordinator.coercedOneShotLanguage(current: nil, allowed: ["en", "pt"]) == nil)
    }

    @Test func resolveLanguageValidatesOneShotRuleAndPinAgainstTheGivenCandidateSet() {
        // A stale one-shot selection referencing a language outside the (snapshotted) candidate
        // set falls through to the app rule, which itself falls through to the pin, exactly like
        // a garbage/unset value would — PLAN.md F5.4's "validated against the snapshotted set at
        // read".
        let viaOneShot = AppCoordinator.resolveLanguage(
            oneShot: "es", bundleID: "com.example.app",
            appLanguageRules: ["com.example.app": "pt"], pin: "en",
            candidateSet: ["en", "pt"]
        )
        #expect(viaOneShot == "pt")

        let viaRule = AppCoordinator.resolveLanguage(
            oneShot: nil, bundleID: "com.example.app",
            appLanguageRules: ["com.example.app": "es"], pin: "en",
            candidateSet: ["en", "pt"]
        )
        #expect(viaRule == "en")

        let viaPin = AppCoordinator.resolveLanguage(
            oneShot: nil, bundleID: nil, appLanguageRules: [:], pin: "es",
            candidateSet: ["en", "pt"]
        )
        #expect(viaPin == nil)

        let allValid = AppCoordinator.resolveLanguage(
            oneShot: "pt", bundleID: nil, appLanguageRules: [:], pin: "en",
            candidateSet: ["en", "pt"]
        )
        #expect(allValid == "pt")
    }

    // MARK: - Snapshot immutability

    @Test func constrainedLanguageArgmaxPicksOnlyAmongCandidates() {
        let langProbs: [String: Float] = ["en": 0.1, "pt": 0.9, "es": 0.99]
        // "es" has the highest overall probability but isn't in the candidate set, so it must
        // never win — this is the constrained-argmax behavior that keeps short-utterance
        // auto-detect from picking a language outside the user's configured set.
        #expect(WhisperKitEngine.constrainedLanguage(langProbs: langProbs, candidates: ["en", "pt"]) == "pt")
    }

    @Test func constrainedLanguageFallsBackWhenCandidatesEmpty() {
        let langProbs: [String: Float] = ["en": 0.9, "pt": 0.1]
        let winner = WhisperKitEngine.constrainedLanguage(langProbs: langProbs, candidates: [])
        #expect(AppSettings.defaultDictationLanguages.contains(winner))
    }

    @Test func inFlightRequestKeepsItsSnapshottedCandidateSetAfterSettingsChangeMidFlight() async throws {
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.dictationLanguages = ["en", "pt"]

        // The snapshot production code actually threads through the pipeline: a `[String]`
        // value captured once (at Recording start / stop-time context construction — see
        // `AppCoordinator.recordingLanguageSnapshot`), not a live re-read of `AppSettings`.
        let snapshot = settings.dictationLanguages
        let engine = CandidateLanguageSpy(output: .init(text: "raw", language: "en"))
        let context = RecordingProcessingContext(
            destination: .external, spokenLanguage: "en", outputLanguage: .sameAsSpoken,
            template: Template(id: "plain", name: "Plain", prompt: "Clean it"),
            cloudSnapshot: nil, candidateLanguages: snapshot
        )

        // Settings mutate AFTER the snapshot was taken but BEFORE the in-flight request resolves
        // — simulating a config change mid-Recording.
        settings.dictationLanguages = ["es", "fr", "de"]

        _ = try await AppCoordinator.shared.processDictation(
            samples: [0.5], engine: engine, engineName: "Spy", context: context,
            insert: { _, _ in true }, record: { _ in }
        )

        #expect(await engine.receivedCandidateLanguages == [["en", "pt"]])
        #expect(settings.dictationLanguages == ["es", "fr", "de"])
    }

    @Test func captureRecordingLanguageSnapshotFreezesPinAndAppLanguageRulesAtCaptureTimeNotLive() {
        // `AppCoordinator.captureRecordingLanguageSnapshot` is called once at Recording start
        // (`beginCapture`/`beginVoiceEditInstructionRecording`) and its RESULT — not a live
        // re-read of `AppSettings` — is what the stop-time `resolveLanguage` call must consult.
        // This proves the capture step itself: value-type fields captured from `settings` are
        // inherently frozen against later mutation of that same `settings` instance, exactly the
        // seam `recordingPinSnapshot`/`recordingAppLanguageRulesSnapshot` rely on to avoid the
        // stop-time live `AppSettings.shared.languagePin`/`appLanguageRules` read this fixes. See
        // Codex finding: stop-time live language-pin/appLanguageRules read.
        let defaults = isolatedDefaults()
        defer { remove(defaults) }
        let settings = AppSettings(defaults: defaults)
        settings.dictationLanguages = ["en", "pt"]
        settings.languagePin = "en"
        settings.appLanguageRules = ["com.example.app": "pt"]

        let snapshot = AppCoordinator.captureRecordingLanguageSnapshot(from: settings)

        // Mutate the SAME settings instance AFTER capturing — simulating the user changing the
        // pin (or an app rule) mid-Recording.
        settings.languagePin = "pt"
        settings.appLanguageRules = ["com.example.app": "en"]

        #expect(snapshot.pin == "en")
        #expect(snapshot.appLanguageRules == ["com.example.app": "pt"])
        #expect(snapshot.candidateLanguages == ["en", "pt"])
        // The live settings really did change — proving the snapshot's stability isn't an
        // accident of nothing having mutated.
        #expect(settings.languagePin == "pt")
        #expect(settings.appLanguageRules == ["com.example.app": "en"])
    }

    // MARK: - Helpers

    private func isolatedDefaults() -> UserDefaults {
        let suite = "DictationLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    private func remove(_ defaults: UserDefaults) {
        let suite = defaults.string(forKey: "testSuiteName")!
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor CandidateLanguageSpy: TranscriptionEngine {
    nonisolated let name = "Spy"
    nonisolated var statusText: String { "Ready" }
    private let output: TranscriptionOutput
    private(set) var receivedCandidateLanguages: [[String]] = []

    init(output: TranscriptionOutput) { self.output = output }

    func transcribe(samples: [Float], forcedLanguage: String?, candidateLanguages: [String], vocabulary: [String]) async throws -> TranscriptionOutput {
        receivedCandidateLanguages.append(candidateLanguages)
        return output
    }
}
