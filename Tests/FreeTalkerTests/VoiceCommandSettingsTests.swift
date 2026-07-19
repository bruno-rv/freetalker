import Foundation
import Testing
@testable import FreeTalker

/// PLAN.md PR A, item 1 — `voiceCommandsEnabled`/`commandKeywords` normalizer, default-off, and
/// persistence tests, mirroring `DictationLanguageTests`'s normalizer coverage pattern.
@Suite("Voice command settings")
@MainActor
struct VoiceCommandSettingsTests {
    // MARK: - Normalizer (bounds / letters-only / dedupe / fallback)

    @Test func normalizerTrimsLowercasesAndDedupes() {
        let normalized = AppSettings.normalizeCommandKeywords([" Command ", "command", "Comando"])
        #expect(normalized == ["command", "comando"])
    }

    @Test func normalizerRejectsDigitsAndPunctuation() {
        let normalized = AppSettings.normalizeCommandKeywords(["c0mmand", "com-ando", "válido"])
        #expect(normalized == ["válido"])
    }

    @Test func normalizerEnforcesTwoToTwentyFourCharacterLength() {
        let tooShort = "a"
        let tooLong = String(repeating: "x", count: 25)
        let justRight = String(repeating: "y", count: 24)
        let normalized = AppSettings.normalizeCommandKeywords([tooShort, tooLong, justRight])
        #expect(normalized == [justRight])
    }

    @Test func normalizerCapsAtFiveEntries() {
        let normalized = AppSettings.normalizeCommandKeywords(["one", "two", "three", "four", "five", "six"])
        #expect(normalized == ["one", "two", "three", "four", "five"])
    }

    @Test func normalizerFallsBackToDefaultWhenEmpty() {
        #expect(AppSettings.normalizeCommandKeywords([]) == AppSettings.defaultCommandKeywords)
    }

    @Test func normalizerFallsBackToDefaultWhenEveryCandidateIsInvalid() {
        #expect(AppSettings.normalizeCommandKeywords(["1", "", "  ", "toolongtoolongtoolongtoolong"]) == AppSettings.defaultCommandKeywords)
    }

    @Test func normalizerAcceptsNonAsciiLetters() {
        #expect(AppSettings.normalizeCommandKeywords(["comando"]) == ["comando"])
    }

    // MARK: - Defaults (off by default, per PLAN.md)

    @Test func voiceCommandsAreDisabledByDefault() throws {
        let suite = "VoiceCommandSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(settings.voiceCommandsEnabled == false)
        #expect(settings.commandKeywords == AppSettings.defaultCommandKeywords)
    }

    // MARK: - Setter re-normalizes and persists

    @Test func settingKeywordsReNormalizesBeforePersisting() throws {
        let suite = "VoiceCommandSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.commandKeywords = [" Ordem ", "ordem", "12345"]

        #expect(settings.commandKeywords == ["ordem"])
        #expect(defaults.array(forKey: "commandKeywords") as? [String] == ["ordem"])
    }

    @Test func toggleAndKeywordsSurviveReloadFromDefaults() throws {
        let suite = "VoiceCommandSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.voiceCommandsEnabled = true
        settings.commandKeywords = ["comando", "hey"]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.voiceCommandsEnabled == true)
        #expect(reloaded.commandKeywords == ["comando", "hey"])
    }

    @Test func legacyStoredKeywordsAreNormalizedOnLoad() throws {
        // A pre-validation UserDefaults value (e.g. written by a future/rolled-back version, or
        // hand-edited) must be normalized on load, not trusted verbatim — mirrors
        // `normalizedCommandKeywords` in `AppSettings.init`.
        let suite = "VoiceCommandSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["not valid 1", "Comando"], forKey: "commandKeywords")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.commandKeywords == ["comando"])
    }

    // MARK: - Stop-time snapshot mirrors current toggle/keywords

    @Test func voiceCommandSnapshotMirrorsCurrentToggleAndKeywords() throws {
        let suite = "VoiceCommandSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceCommandsEnabled = true
        settings.commandKeywords = ["comando"]

        #expect(settings.voiceCommandSnapshot == VoiceCommandSnapshot(enabled: true, keywords: ["comando"]))
    }

    // MARK: - Toggle-off commit ordering (Codex round-5 finding 7)

    /// A pending keyword edit still sitting in the text field's local buffer must be committed
    /// BEFORE the toggle flips off and the field is removed from the view hierarchy — relying
    /// solely on SwiftUI's focus-loss `.onChange` firing first is not guaranteed.
    @Test func toggleOffCommitsPendingKeywordsBeforeDisabling() {
        var order: [String] = []

        VoiceCommandsToggleCommit.apply(
            false,
            commitPendingKeywords: { order.append("commit") },
            setEnabled: { order.append("setEnabled(\($0))") }
        )

        #expect(order == ["commit", "setEnabled(false)"])
    }

    @Test func toggleOnNeverCommitsPendingKeywords() {
        var order: [String] = []

        VoiceCommandsToggleCommit.apply(
            true,
            commitPendingKeywords: { order.append("commit") },
            setEnabled: { order.append("setEnabled(\($0))") }
        )

        #expect(order == ["setEnabled(true)"])
    }

    // MARK: - Keywords buffer dirty-tracking (Codex round-6 finding 6)

    /// Backup Bundle restore can update `settings.commandKeywords` while the Templates pane is
    /// mounted but not visible. An untouched (clean) buffer must always pick up the live value —
    /// otherwise the restore is invisible until the user happens to revisit the field.
    @Test func cleanBufferAlwaysResyncsToTheLiveValue() {
        let result = VoiceCommandsKeywordsBuffer.reconciled(
            isDirty: false, liveKeywords: ["restored", "again"], currentText: "stale"
        )
        #expect(result == "restored, again")
    }

    /// An in-progress user edit must never be silently discarded by an unrelated settings change
    /// (e.g. a restore landing on a different Settings tab).
    @Test func dirtyBufferIsNeverOverwrittenBySettingsChanges() {
        let result = VoiceCommandsKeywordsBuffer.reconciled(
            isDirty: true, liveKeywords: ["restored"], currentText: "still typing…"
        )
        #expect(result == "still typing…")
    }

    /// A clean buffer already tracks the live value, so committing it on toggle-off must be a
    /// no-op — otherwise it would clobber a restore that landed while the buffer sat untouched
    /// (this is the exact Codex round-6 finding 6 regression).
    @Test func cleanBufferNeverCommitsOnToggleOff() {
        #expect(VoiceCommandsKeywordsBuffer.shouldCommit(isDirty: false) == false)
    }

    @Test func dirtyBufferCommitsOnToggleOff() {
        #expect(VoiceCommandsKeywordsBuffer.shouldCommit(isDirty: true) == true)
    }
}
