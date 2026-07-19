import Foundation
import Testing
@testable import FreeTalker

/// Backup Bundle round-trip for the self-learning vocabulary decisions stage (PLAN.md PR B, item
/// 2c) — a dedicated env/helper (rather than reusing `BackupBundleTests`' shared `Env`) so this
/// file's `VocabStore` wiring doesn't touch that suite's many existing call sites, all of which
/// already default `vocabStore` to `nil` and are unaffected by this stage's addition.
@MainActor
@Suite struct VocabularyBackupTests {
    @Test func roundTripMergesABrandNewDecisionIntoAnEmptyStore() async throws {
        let source = try makeEnv()
        let destination = try makeEnv()
        _ = try await source.vocabStore.mergeDecisions([
            VocabDecision(normalizedTerm: "joão", status: .approved, surfaceTerm: "João", decidedAt: Date(timeIntervalSince1970: 100))
        ])

        let data = try await BackupBundle.export(
            settings: source.settings, templateStore: source.templateStore, snippetStore: source.snippetStore, vocabStore: source.vocabStore
        )
        let result = try await BackupBundle.restore(
            data: data, settings: destination.settings, templateStore: destination.templateStore,
            snippetStore: destination.snippetStore, vocabStore: destination.vocabStore
        )

        #expect(result.vocabDecisionsImported == 1)
        #expect(result.vocabDecisionsSkipped == 0)
        #expect(try await destination.vocabStore.approvedTerms().map(\.surfaceTerm) == ["João"])
    }

    /// PLAN.md PR B, item 2c: merge-by-newer — the destination's already-newer decision survives
    /// a restore of an older one for the same term.
    @Test func roundTripSkipsWhenDestinationDecisionIsAlreadyNewer() async throws {
        let source = try makeEnv()
        let destination = try makeEnv()
        _ = try await source.vocabStore.mergeDecisions([
            VocabDecision(normalizedTerm: "joão", status: .dismissed, surfaceTerm: nil, decidedAt: Date(timeIntervalSince1970: 100))
        ])
        _ = try await destination.vocabStore.mergeDecisions([
            VocabDecision(normalizedTerm: "joão", status: .approved, surfaceTerm: "João", decidedAt: Date(timeIntervalSince1970: 200))
        ])

        let data = try await BackupBundle.export(
            settings: source.settings, templateStore: source.templateStore, snippetStore: source.snippetStore, vocabStore: source.vocabStore
        )
        let result = try await BackupBundle.restore(
            data: data, settings: destination.settings, templateStore: destination.templateStore,
            snippetStore: destination.snippetStore, vocabStore: destination.vocabStore
        )

        #expect(result.vocabDecisionsImported == 0)
        #expect(result.vocabDecisionsSkipped == 1)
        #expect(try await destination.vocabStore.approvedTerms().map(\.surfaceTerm) == ["João"])
    }

    /// The mirror case: the destination's decision is OLDER, so the restored one replaces it.
    @Test func roundTripReplacesWhenDestinationDecisionIsOlder() async throws {
        let source = try makeEnv()
        let destination = try makeEnv()
        _ = try await source.vocabStore.mergeDecisions([
            VocabDecision(normalizedTerm: "joão", status: .dismissed, surfaceTerm: nil, decidedAt: Date(timeIntervalSince1970: 300))
        ])
        _ = try await destination.vocabStore.mergeDecisions([
            VocabDecision(normalizedTerm: "joão", status: .approved, surfaceTerm: "João", decidedAt: Date(timeIntervalSince1970: 100))
        ])

        let data = try await BackupBundle.export(
            settings: source.settings, templateStore: source.templateStore, snippetStore: source.snippetStore, vocabStore: source.vocabStore
        )
        let result = try await BackupBundle.restore(
            data: data, settings: destination.settings, templateStore: destination.templateStore,
            snippetStore: destination.snippetStore, vocabStore: destination.vocabStore
        )

        #expect(result.vocabDecisionsImported == 1)
        #expect(try await destination.vocabStore.approvedTerms().isEmpty)
        #expect(try await destination.vocabStore.decisions().first?.status == .dismissed)
    }

    /// A restore target with no `vocabStore` (e.g. it failed to initialize) and a bundle that
    /// genuinely has NO vocab decisions to apply skips the stage silently — nothing was lost,
    /// same degrade-gracefully contract as `snippetStore`/`recoveryStore` elsewhere in
    /// `AppCoordinator`.
    @Test func restoreWithoutADestinationVocabStoreAndNoDecisionsInTheBundleSkipsTheStageWithoutError() async throws {
        let source = try makeEnv()
        let destination = try makeEnv()
        let data = try await BackupBundle.export(
            settings: source.settings, templateStore: source.templateStore, snippetStore: source.snippetStore, vocabStore: source.vocabStore
        )

        let result = try await BackupBundle.restore(
            data: data, settings: destination.settings, templateStore: destination.templateStore, snippetStore: destination.snippetStore
        )

        #expect(result.vocabDecisionsImported == 0)
        #expect(result.vocabDecisionsSkipped == 0)
    }

    /// PLAN.md PR B, item 2c / Codex round 1 finding 7: a restore target with no `vocabStore`
    /// but a bundle that DOES carry decisions must fail the named `vocabDecisions` stage
    /// explicitly — never report a plain success that silently dropped the restored
    /// approve/dismiss decisions. Every OTHER stage's partial progress must still be preserved
    /// on the thrown error (same `.stageFailed` contract as templates/snippets).
    @Test func restoreWithoutADestinationVocabStoreButWithDecisionsInTheBundleFailsTheStageExplicitly() async throws {
        let source = try makeEnv()
        let destination = try makeEnv()
        _ = try await source.vocabStore.mergeDecisions([
            VocabDecision(normalizedTerm: "joão", status: .approved, surfaceTerm: "João", decidedAt: Date(timeIntervalSince1970: 100))
        ])
        let data = try await BackupBundle.export(
            settings: source.settings, templateStore: source.templateStore, snippetStore: source.snippetStore, vocabStore: source.vocabStore
        )

        await #expect(throws: BackupBundleError.self) {
            try await BackupBundle.restore(
                data: data, settings: destination.settings, templateStore: destination.templateStore, snippetStore: destination.snippetStore
            )
        }
        do {
            _ = try await BackupBundle.restore(
                data: data, settings: destination.settings, templateStore: destination.templateStore, snippetStore: destination.snippetStore
            )
            Issue.record("expected .stageFailed(stage: \"vocabDecisions\", ...)")
        } catch BackupBundleError.stageFailed(let stage, let partial, _) {
            #expect(stage == "vocabDecisions")
            // Templates/snippets already committed before this stage runs — must be preserved,
            // not lost, by the thrown error.
            #expect(partial.settingsApplied == false)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// A bundle exported without a `vocabStore` (feature unavailable that session) omits the key
    /// entirely — restoring it must not error, and must leave the destination's own decisions
    /// untouched (nothing to merge).
    @Test func exportWithoutASourceVocabStoreOmitsTheStageOnRestoreToo() async throws {
        let source = try makeEnv()
        let destination = try makeEnv()
        _ = try await destination.vocabStore.mergeDecisions([
            VocabDecision(normalizedTerm: "existing", status: .approved, surfaceTerm: "Existing", decidedAt: Date(timeIntervalSince1970: 1))
        ])
        let data = try await BackupBundle.export(settings: source.settings, templateStore: source.templateStore, snippetStore: source.snippetStore)

        let result = try await BackupBundle.restore(
            data: data, settings: destination.settings, templateStore: destination.templateStore,
            snippetStore: destination.snippetStore, vocabStore: destination.vocabStore
        )

        #expect(result.vocabDecisionsImported == 0)
        #expect(try await destination.vocabStore.approvedTerms().map(\.surfaceTerm) == ["Existing"])
    }

    /// PLAN.md PR B, item 2c / Codex round 1 finding 6: a hand-edited bundle whose approved
    /// decision has a `normalizedTerm` that doesn't match its own `surfaceTerm`'s canonical
    /// lowercased form must be rejected outright — never committed under a mismatched key.
    @Test func restoreRejectsAnApprovedDecisionWhoseNormalizedTermDoesNotMatchItsCanonicalSurface() async throws {
        let destination = try makeEnv()
        let data = try await Self.malformedVocabBundle(destination: destination, decisions: [
            ["normalizedTerm": "wrongkey", "status": "approved", "surfaceTerm": "João", "decidedAt": 100.0]
        ])

        await #expect(throws: BackupBundleError.invalidVocabDecisionsSection) {
            try await BackupBundle.restore(
                data: data, settings: destination.settings, templateStore: destination.templateStore,
                snippetStore: destination.snippetStore, vocabStore: destination.vocabStore
            )
        }
        #expect(try await destination.vocabStore.approvedTerms().isEmpty)
    }

    /// Same trust boundary, the other direction: a restored surface containing a control
    /// character must never be committed even though it passes the plain emptiness/byte-length
    /// checks.
    @Test func restoreRejectsAnApprovedDecisionWithAControlCharacterInItsSurface() async throws {
        let destination = try makeEnv()
        let data = try await Self.malformedVocabBundle(destination: destination, decisions: [
            ["normalizedTerm": "bad\u{0007}term", "status": "approved", "surfaceTerm": "bad\u{0007}term", "decidedAt": 100.0]
        ])

        await #expect(throws: BackupBundleError.invalidVocabDecisionsSection) {
            try await BackupBundle.restore(
                data: data, settings: destination.settings, templateStore: destination.templateStore,
                snippetStore: destination.snippetStore, vocabStore: destination.vocabStore
            )
        }
        #expect(try await destination.vocabStore.approvedTerms().isEmpty)
    }

    /// PLAN.md PR B, item 2c / Codex round 1 finding 8: export enforces the SAME 2,000-decision
    /// bound restore does — a store that somehow accumulated more decisions than the cap must
    /// fail export explicitly rather than silently produce a bundle FreeTalker's own restore
    /// would then unconditionally reject.
    @Test func exportFailsWhenTheStoreExceedsTheRestoreBound() async throws {
        let source = try makeEnv()
        let tooMany = (0..<(BackupBundleBounds.maxVocabDecisions + 1)).map { index in
            VocabDecision(normalizedTerm: "term\(index)", status: .dismissed, surfaceTerm: nil, decidedAt: Date(timeIntervalSince1970: Double(index)))
        }
        _ = try await source.vocabStore.mergeDecisions(tooMany)

        await #expect(throws: BackupBundleError.tooManyVocabDecisions(max: BackupBundleBounds.maxVocabDecisions)) {
            try await BackupBundle.export(
                settings: source.settings, templateStore: source.templateStore, snippetStore: source.snippetStore, vocabStore: source.vocabStore
            )
        }
    }

    /// Builds a valid v2 envelope (via a real, empty export) and splices in a hand-crafted
    /// `vocabDecisions` array — the only way to exercise restore's validator against a
    /// deliberately-malformed row, since `VocabStore`'s own writes can never produce one.
    private static func malformedVocabBundle(destination: Env, decisions: [[String: Any]]) async throws -> Data {
        let base = try await BackupBundle.export(
            settings: destination.settings, templateStore: destination.templateStore, snippetStore: destination.snippetStore
        )
        var payload = try #require(try JSONSerialization.jsonObject(with: base) as? [String: Any])
        payload["vocabDecisions"] = decisions
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Helpers

    private struct Env {
        let settings: AppSettings
        let templateStore: TemplateStore
        let snippetStore: SnippetStore
        let vocabStore: VocabStore
    }

    private func makeEnv() throws -> Env {
        let suite = "VocabularyBackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let templatesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        let snippetsDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        let libraryDatabaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("sqlite")
        return Env(
            settings: AppSettings(defaults: defaults),
            templateStore: TemplateStore(fileURL: templatesDirectory.appendingPathComponent("templates.json"), defaults: defaults),
            snippetStore: try SnippetStore(databaseURL: snippetsDatabaseURL),
            vocabStore: try VocabStore(databaseURL: libraryDatabaseURL)
        )
    }
}
