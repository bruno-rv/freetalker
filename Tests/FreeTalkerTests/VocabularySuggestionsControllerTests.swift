import Foundation
import Testing
@testable import FreeTalker

/// PLAN.md PR B, item 4: approval is GATED on the term provably fitting — `VocabularySuggestionsController.approve`
/// checks prospective fit BEFORE ever calling `store.approve`, so a term that doesn't fit is
/// rejected with an explanation and the decision is never written (no "approved but silently
/// inactive" state). See Codex round 1 finding 1.
@Suite @MainActor struct VocabularySuggestionsControllerTests {
    @Test func approvingATermThatDoesNotFitIsRejectedAndNeverRecordsADecision() async throws {
        let url = temporaryDatabaseURL()
        let dbLibrary = try Database(path: url)
        let id = try dbLibrary.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        let suggestion = try #require(try await store.suggestions(minimumRecurrence: 1, limit: 25).first)

        let controller = VocabularySuggestionsController(
            store: { store },
            library: .shared,
            onDecisionApplied: {},
            displacedTerms: { [] },
            wouldFit: { _ in false }
        )

        controller.approve(suggestion)
        await controller.waitForCurrentAction()

        #expect(controller.errorMessage?.contains("João") == true)
        #expect(controller.displacedWarning == nil)
        #expect(try await store.approvedTerms().isEmpty)
        #expect(try await store.suggestions(minimumRecurrence: 1, limit: 25).map(\.normalizedTerm) == ["joão"])
    }

    @Test func approvingATermThatFitsRecordsTheDecisionAndLeavesTheWarningUnset() async throws {
        let url = temporaryDatabaseURL()
        let dbLibrary = try Database(path: url)
        let id = try dbLibrary.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        let suggestion = try #require(try await store.suggestions(minimumRecurrence: 1, limit: 25).first)

        let controller = VocabularySuggestionsController(
            store: { store },
            library: .shared,
            onDecisionApplied: {},
            displacedTerms: { [] },
            wouldFit: { _ in true }
        )

        controller.approve(suggestion)
        await controller.waitForCurrentAction()

        #expect(controller.errorMessage == nil)
        #expect(controller.displacedWarning == nil)
        #expect(try await store.approvedTerms().map(\.surfaceTerm) == ["João"])
    }

    /// The race-safety fallback: the `wouldFit` gate passes (so `store.approve` runs), but
    /// `displacedTerms` — read again right after the write, mirroring a real post-approval
    /// `AppSettings` snapshot — reports the term landed displaced anyway (e.g. a concurrent
    /// decision or manual edit raced the gate). See `approve(_:)`'s doc comment.
    @Test func raceBetweenGateAndWriteStillSurfacesADisplacedWarning() async throws {
        let url = temporaryDatabaseURL()
        let dbLibrary = try Database(path: url)
        let id = try dbLibrary.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        let suggestion = try #require(try await store.suggestions(minimumRecurrence: 1, limit: 25).first)

        let controller = VocabularySuggestionsController(
            store: { store },
            library: .shared,
            onDecisionApplied: {},
            displacedTerms: { ["João"] },
            wouldFit: { _ in true }
        )

        controller.approve(suggestion)
        await controller.waitForCurrentAction()

        #expect(controller.displacedWarning?.contains("João") == true)
        #expect(try await store.approvedTerms().map(\.surfaceTerm) == ["João"])
    }

    /// Before serializing `approve`/`dismiss` behind the in-flight `actionTask`, two rapid
    /// `approve()` calls started concurrently: the second's `wouldFit` check could run before the
    /// first's `onDecisionApplied()` had republished the cache, so it evaluated "termB alone"
    /// instead of "termB alongside the just-approved termA" — letting BOTH land even though
    /// together they exceed `VocabularyFitGate.tokenBudget`. See Codex finding
    /// (VocabularySuggestionsController.swift:94).
    @Test func rapidApprovalsProcessSequentiallySoTheSecondSeesTheFirstsUpdatedCache() async throws {
        let url = temporaryDatabaseURL()
        let dbLibrary = try Database(path: url)
        let store = try VocabStore(databaseURL: url)
        let id = try dbLibrary.insertDictation(makeInsertRequest(transcript: "hello", refined: "hello"))

        // 4 filler user terms (21 bytes each, 91 bytes serialized) leave just enough budget
        // (VocabularyFitGate.tokenBudget, ~111 bytes) for ONE more 10-byte approved term, never
        // two — see this file's suite-level math in the comment on `termA`/`termB` below.
        let fillerTerms = (0..<4).map { "filler-term-number-\(String(format: "%02d", $0))" }
        let suite = "VocabularySuggestionsControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.vocabularyText = fillerTerms.joined(separator: "\n")

        // Each alone fits comfortably (91 + 2 + 10 = 103 <= tokenBudget); together they don't
        // (91 + 2 + 10 + 2 + 10 = 115 > tokenBudget).
        let termA = "ApprovedA1"
        let termB = "ApprovedB2"
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: termA.lowercased(), surfaceTerm: termA)])
        try await store.recordEvidence(dictationID: id, candidates: [VocabEvidenceCandidate(normalizedTerm: termB.lowercased(), surfaceTerm: termB)])

        let controller = VocabularySuggestionsController(
            store: { store },
            library: .shared,
            onDecisionApplied: {
                let fresh = (try? await store.approvedTerms()) ?? []
                settings.applyApprovedVocabularyCache(fresh)
            },
            displacedTerms: { settings.displacedApprovedVocabularyTerms },
            wouldFit: { surfaceTerm in
                let userTerms = AppSettings.boundedVocabulary(settings.vocabularyText).kept
                let existingApproved = settings.approvedVocabularyCache.map(\.surfaceTerm)
                let result = EffectiveVocabulary.derive(userTerms: userTerms, approvedTerms: existingApproved + [surfaceTerm])
                return !result.displaced.contains(surfaceTerm)
            }
        )

        controller.approve(VocabSuggestion(normalizedTerm: termA.lowercased(), surfaceTerm: termA, recurrence: 1, mostRecentSeenAt: Date()))
        controller.approve(VocabSuggestion(normalizedTerm: termB.lowercased(), surfaceTerm: termB, recurrence: 1, mostRecentSeenAt: Date()))
        await controller.waitForCurrentAction()

        // Only A landed: by the time B's `wouldFit` ran, A's decision + cache refresh had already
        // completed, so B correctly saw A already occupying the remaining budget.
        #expect(try await store.approvedTerms().map(\.surfaceTerm) == [termA])
        #expect(controller.errorMessage?.contains(termB) == true)
    }

    /// Blocker fix: `store` is an accessor resolved fresh on every action, not a value captured
    /// once at `init` — otherwise a controller constructed while `AppCoordinator.vocabStore` is
    /// still `nil` (the deferred `Task` in `AppCoordinator.private init()` hasn't landed yet, but
    /// `@StateObject` already mounted the controller because Settings opened) would show
    /// "storage isn't available" for its entire lifetime, even after the store shows up. See
    /// `SettingsView.swift`'s `@StateObject private var vocabularySuggestions =
    /// VocabularySuggestionsController()` mounting immediately when Settings opens.
    @Test func storeBecomingAvailableAfterConstructionIsPickedUpWithoutReconstruction() async throws {
        let url = temporaryDatabaseURL()
        let dbLibrary = try Database(path: url)
        // Two DISTINCT dictations: `performRefresh` calls `store.suggestions()` with its default
        // `minimumRecurrence` (`VocabStore.minimumRecurrence`, 2 — recurrence counts distinct
        // dictation IDs), unlike other tests in this file that override it to 1.
        let firstID = try dbLibrary.insertDictation(makeInsertRequest(transcript: "hello joao", refined: "hello João"))
        let secondID = try dbLibrary.insertDictation(makeInsertRequest(transcript: "hi joao", refined: "hi João"))
        let store = try VocabStore(databaseURL: url)
        try await store.recordEvidence(dictationID: firstID, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])
        try await store.recordEvidence(dictationID: secondID, candidates: [VocabEvidenceCandidate(normalizedTerm: "joão", surfaceTerm: "João")])

        let resolver = StoreResolver()
        let controller = VocabularySuggestionsController(
            store: { resolver.store },
            library: .shared,
            onDecisionApplied: {},
            displacedTerms: { [] },
            wouldFit: { _ in true }
        )

        // Mirrors the race: Settings opens (controller constructed) before `AppCoordinator`'s
        // deferred store setup lands.
        #expect(controller.isAvailable == false)
        controller.refreshSuggestions()
        await controller.waitForCurrentAction()
        #expect(controller.suggestions.isEmpty)

        // The store shows up later, same controller instance — no reconstruction.
        resolver.store = store
        #expect(controller.isAvailable == true)
        controller.refreshSuggestions()
        await controller.waitForCurrentAction()
        #expect(controller.suggestions.map(\.normalizedTerm) == ["joão"])
    }
}

/// Mutable box standing in for `AppCoordinator.vocabStore` transitioning from `nil` to set once
/// its deferred setup `Task` lands.
private final class StoreResolver {
    var store: VocabStore?
}

private func makeInsertRequest(transcript: String, refined: String) -> DictationInsertRequest {
    .init(
        timestamp: Date(), sourceLanguage: SourceLanguage("en"),
        requestedOutputLanguage: .sameAsSpoken, template: "Clean",
        transcript: transcript, refined: refined, engine: "local",
        voiceCommandsActive: false
    )
}

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}
