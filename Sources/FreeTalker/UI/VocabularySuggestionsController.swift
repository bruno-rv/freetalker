import Foundation

/// Drives the Settings "Vocabulary Suggestions" section (PLAN.md PR B, item 6): the ranked
/// suggestions list, approve/dismiss, and the "Scan library" backfill with progress + cancel.
/// Mirrors `LibraryTranslationController`'s generation-counter cancellation idiom.
@MainActor
final class VocabularySuggestionsController: ObservableObject {
    @Published private(set) var suggestions: [VocabSuggestion] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: VocabularyScanService.ScanProgress?
    @Published var errorMessage: String?

    /// Set if an in-flight `approve()`'s prospective-fit check and the actual write raced (see
    /// `approve(_:)`) and the term landed displaced anyway — belt-and-suspenders; the normal path
    /// never reaches this because `approve(_:)` refuses to write a decision that doesn't provably
    /// fit. See PLAN.md PR B, item 4 ("approvals never silently inactive").
    @Published var displacedWarning: String?

    /// Resolves the live `VocabStore`, called fresh on every action rather than captured once —
    /// `AppCoordinator.vocabStore` is constructed asynchronously, off the synchronous launch path
    /// (see `AppCoordinator.setUpVocabularyStore`), and this controller is mounted immediately via
    /// `@StateObject` when Settings opens. Capturing `AppCoordinator.shared.vocabStore` once at
    /// `init` would freeze `nil` for this controller's entire lifetime if Settings opens before
    /// that deferred `Task` lands, permanently showing "storage isn't available" until relaunch.
    /// Reading it live matches how `wouldFit`/`displacedTerms` already read shared state live.
    /// `nil` when `VocabStore` failed to initialize, or hasn't finished initializing yet — the
    /// section shows an unavailable message instead (same degrade-gracefully contract as
    /// `AppCoordinator.snippetStore`/`recoveryStore`).
    private let store: () -> VocabStore?
    private let library: LibraryStore
    private let onDecisionApplied: () async -> Void
    private let displacedTerms: @MainActor () -> [String]
    /// Prospective-fit check (PLAN.md PR B, item 4: "approval is gated on the term provably
    /// fitting the effective vocabulary budget... does not provably fit → explicit eviction
    /// choice or rejection"): given a candidate surface term, reports whether it would land in
    /// `EffectiveVocabulary`'s `active` set (or harmlessly dedupe against an already-active term)
    /// if approved right now, alongside the CURRENT `vocabularyText` and already-approved terms —
    /// never `displaced`. Default reads live `AppSettings.shared`; injectable for tests.
    private let wouldFit: @MainActor (String) -> Bool
    private var scanTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var generation = 0

    /// Lets tests await the in-flight `approve`/`dismiss`/`refreshSuggestions` call instead of
    /// polling — mirrors `LibraryTranslationController.waitForCurrentRequest()`.
    func waitForCurrentAction() async { await actionTask?.value }

    var isAvailable: Bool { store() != nil }

    init(
        store: @escaping () -> VocabStore? = { AppCoordinator.shared.vocabStore },
        library: LibraryStore = .shared,
        onDecisionApplied: @escaping () async -> Void = { await AppCoordinator.shared.refreshApprovedVocabularyCache() },
        displacedTerms: @escaping @MainActor () -> [String] = { AppSettings.shared.displacedApprovedVocabularyTerms },
        wouldFit: @escaping @MainActor (String) -> Bool = { surfaceTerm in
            let settings = AppSettings.shared
            let userTerms = AppSettings.boundedVocabulary(settings.vocabularyText).kept
            let existingApproved = settings.approvedVocabularyCache.map(\.surfaceTerm)
            // Same live encoder `effectiveVocabulary` uses (PLAN.md PR B, item 4) — approval-time
            // and read-time must agree on tokenizer-loaded-vs-not for "approved ⇒ active" to hold.
            let result = EffectiveVocabulary.derive(
                userTerms: userTerms, approvedTerms: existingApproved + [surfaceTerm],
                encode: settings.vocabularyTokenEncoder?()
            )
            return !result.displaced.contains(surfaceTerm)
        }
    ) {
        self.store = store
        self.library = library
        self.onDecisionApplied = onDecisionApplied
        self.displacedTerms = displacedTerms
        self.wouldFit = wouldFit
    }

    /// Called from `.onAppear` on the suggestions section, and after every mutating action below
    /// — the simplest sufficient freshness contract for an on-demand Settings list (see
    /// `LibraryStore.onDictationRecorded`'s doc comment: mining/evidence changes elsewhere, e.g.
    /// Delete All clearing evidence on `LibraryStore`'s own connection, aren't observed here until
    /// the next explicit refresh).
    func refreshSuggestions() {
        guard store() != nil else { return }
        actionTask = Task { await performRefresh() }
    }

    private func performRefresh() async {
        guard let store = store() else { return }
        let requestGeneration = generation
        do {
            let fetched = try await store.suggestions()
            guard requestGeneration == generation else { return }
            suggestions = fetched
        } catch {
            guard requestGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// PLAN.md PR B, item 4: approval is GATED on the term provably fitting — `wouldFit` is
    /// evaluated BEFORE `store.approve` ever runs, so a term that doesn't fit is rejected with an
    /// explanation and never recorded as a decision (no "approved but silently inactive" state).
    /// Once approved, a LATER manual `vocabularyText` edit can still legitimately displace it —
    /// that post-approval displacement is `EffectiveVocabulary`'s existing, unchanged machinery
    /// (surfaced in Settings via `AppSettings.displacedApprovedVocabularyTerms`), not this gate.
    ///
    /// Chains behind whatever `actionTask` is already in flight (see `dismiss`) instead of
    /// starting concurrently: two rapid decisions each reassign `actionTask` immediately, so
    /// without this a second `wouldFit` check could run before the first decision's
    /// `onDecisionApplied()` has republished the cache it needs to see, letting two terms that
    /// individually fit both get approved even though they don't fit together. Awaiting the
    /// PREVIOUS task (not cancelling it) keeps every fit-check+write+cache-refresh atomic per
    /// decision, in submission order.
    func approve(_ suggestion: VocabSuggestion) {
        guard let store = store() else { return }
        let previousAction = actionTask
        actionTask = Task {
            await previousAction?.value
            guard wouldFit(suggestion.surfaceTerm) else {
                errorMessage = "\"\(suggestion.surfaceTerm)\" doesn't fit alongside your current vocabulary — dismiss an approved term or shorten your manual list, then approve again."
                return
            }
            do {
                _ = try await store.approve(normalizedTerm: suggestion.normalizedTerm)
                await onDecisionApplied()
                // Belt-and-suspenders: catches the (rare) race where another decision or a manual
                // vocabularyText edit landed between the `wouldFit` check above and this write —
                // never the normal path, since the gate above already refused a non-fitting term.
                if displacedTerms().contains(suggestion.surfaceTerm) {
                    displacedWarning = "\"\(suggestion.surfaceTerm)\" was approved but doesn't fit alongside your current vocabulary — it stays inactive until you dismiss another approved term or shorten your manual list."
                }
                await performRefresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Same serialization as `approve` (see its doc comment) — a dismiss racing an approve (either
    /// order) must not let the second one's fit-check run against a stale cache.
    func dismiss(_ normalizedTerm: String) {
        guard let store = store() else { return }
        let previousAction = actionTask
        actionTask = Task {
            await previousAction?.value
            do {
                _ = try await store.dismiss(normalizedTerm: normalizedTerm)
                await onDecisionApplied()
                await performRefresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Full paged backfill (PLAN.md PR B, item 3/6) — cancellable, reports progress. A second call
    /// while already scanning is a no-op (the button is disabled in the UI while `isScanning`).
    func scanLibrary() {
        guard let store = store(), !isScanning else { return }
        generation += 1
        let requestGeneration = generation
        isScanning = true
        scanProgress = nil
        errorMessage = nil
        scanTask = Task {
            do {
                try await VocabularyScanService.scanLibrary(library: library, store: store) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, requestGeneration == self.generation else { return }
                        self.scanProgress = progress
                    }
                }
                guard requestGeneration == generation else { return }
                isScanning = false
                refreshSuggestions()
            } catch is CancellationError {
                guard requestGeneration == generation else { return }
                isScanning = false
            } catch {
                guard requestGeneration == generation else { return }
                isScanning = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelScan() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}
