import Foundation

/// Pure mining logic for the self-learning vocabulary feature (PLAN.md PR B, item 1) — no I/O, no
/// actor isolation, independently testable. `VocabularyScanService` is the only caller in
/// production.
enum VocabularyMiner {
    /// Candidates must correct a term at least this long (both the transcript's original token
    /// and the refined replacement) — short common words produce noisy false positives at small
    /// edit distances. Tunable (PLAN.md "Risks").
    static let minTermLength = 4
    /// Maximum Levenshtein distance (on the lowercased forms) admitted as a "spelling fix" rather
    /// than an unrelated word. Tunable (PLAN.md "Risks").
    static let maxEditDistance = 2
    /// Per-dictation cap — mirrors `VocabStore.maxCandidatesPerDictation`. See PLAN.md PR B, item 1.
    static let maxCandidatesPerDictation = 10
    /// Ponytail safety valve: an LCS diff is O(n·m) in token count, and the table is a single
    /// `(n+1)*(m+1)`-`Int` allocation (see `replacementHunks`) — 2,000 was an arbitrary round
    /// number that let that allocation reach ~32MB for one dictation. PLAN.md PR B, item 1 itself
    /// only claims "anchored local substitutions," and a few hundred tokens (a few minutes of
    /// continuous speech) is already far more than a spoken-then-refined pass produces, so 500 is
    /// still generous headroom, not a tight fit — skipping mining for anything longer is the
    /// simplest correct bound (PLAN.md never requires mining every row, only benign, idempotent,
    /// bounded mining).
    static let maxTokenCountForDiff = 500

    /// Eligibility (PLAN.md PR B, item 1): same-language (not a translation), not the raw
    /// transcript (a template refinement occurred), and voice commands NOT active for this row.
    /// `voiceCommandsActive == nil` (legacy/unknown — PR A's tri-state contract) is EXCLUDED, same
    /// as `true` — never assumed safe. `voice_commands_active == false` alone is not sufficient by
    /// itself either: PR A also writes `false` for raw and translated rows (see
    /// `AppCoordinator.derivedVoiceCommandsActive`), so both the language and template checks
    /// below are required alongside it, not redundant with it.
    static func isEligible(requestedOutputLanguage: OutputLanguage, templateName: String, voiceCommandsActive: Bool?) -> Bool {
        guard requestedOutputLanguage == .sameAsSpoken else { return false }
        guard !TemplateStore.isReservedTemplateName(templateName) else { return false }
        return voiceCommandsActive == false
    }

    /// Anchored local substitutions between `transcript` (raw STT) and `refined` (post-processed):
    /// a token-level LCS diff (`replacementHunks`) whose matched tokens are the "anchor" either
    /// side of every changed run. Only 1-for-1 hunks — exactly one transcript token replaced by
    /// exactly one refined token, both anchored by matching context — are candidates; any hunk
    /// replacing/inserting/deleting more than one token (a genuine rewrite, a reordering, added or
    /// removed content) yields no candidate for that hunk, which is what makes a whole-sentence
    /// rewrite produce zero candidates while a single spelling/casing fix produces exactly one.
    /// See PLAN.md PR B, item 1.
    static func candidates(transcript: String, refined: String) -> [VocabEvidenceCandidate] {
        let oldTokens = tokenize(transcript)
        let newTokens = tokenize(refined)
        guard !oldTokens.isEmpty, !newTokens.isEmpty,
              oldTokens.count <= maxTokenCountForDiff, newTokens.count <= maxTokenCountForDiff
        else { return [] }

        var results: [VocabEvidenceCandidate] = []
        for hunk in replacementHunks(old: oldTokens, new: newTokens) {
            guard results.count < maxCandidatesPerDictation else { break }
            guard hunk.oldTokens.count == 1, hunk.newTokens.count == 1 else { continue }
            guard hunk.hasLeftAnchor, hunk.hasRightAnchor else { continue }
            let oldWord = hunk.oldTokens[0]
            let newWord = hunk.newTokens[0]
            guard oldWord.count >= minTermLength, newWord.count >= minTermLength else { continue }
            guard oldWord != newWord else { continue }
            let normalizedOld = oldWord.lowercased()
            let normalizedNew = newWord.lowercased()
            let isCasingOnlyFix = normalizedOld == normalizedNew
            guard isCasingOnlyFix || levenshteinDistance(normalizedOld, normalizedNew) <= maxEditDistance else { continue }
            // PLAN.md PR B, item 2b: mined terms go through the SAME shared NFC/control-character/
            // 50-byte validator manual and approved terms use — never a separate, looser mining
            // cap. A candidate that fails it is dropped here, at evidence creation, rather than
            // being stored and only silently excluded later by `EffectiveVocabulary` (which would
            // let it sit forever as a "suggestion" nothing can ever actually approve into an
            // active state). `normalizedTerm` is derived from the CANONICAL (validated,
            // NFC-precomposed) surface, not the raw token, so evidence rows for two different
            // Unicode normalization forms of the same spelling always collapse to one term. See
            // Codex round 1 finding 5.
            guard let canonicalSurface = AppSettings.validatedVocabularyTerm(newWord) else { continue }
            results.append(VocabEvidenceCandidate(normalizedTerm: canonicalSurface.lowercased(), surfaceTerm: canonicalSurface))
        }
        return results
    }

    /// Whitespace-delimited tokens with surrounding punctuation trimmed (so "João." and "João"
    /// compare equal, and sentence punctuation never pollutes a mined term).
    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    struct ReplacementHunk: Equatable {
        let oldTokens: [String]
        let newTokens: [String]
        /// Whether a matched (anchor) token immediately precedes/follows this hunk on each side —
        /// false at the true start/end of the transcript, where there is no surrounding matched
        /// context to anchor the substitution. See PLAN.md PR B, item 1 ("anchored local
        /// substitutions") and Codex round 1 minor finding (`VocabularyMiner.swift:51`): without
        /// this, a whole-transcript one-token replacement, or a substitution at the very first/last
        /// token, was accepted despite having no anchoring context on one or both sides.
        let hasLeftAnchor: Bool
        let hasRightAnchor: Bool
    }

    /// Maximal-run LCS diff: walks the two token arrays via a standard longest-common-subsequence
    /// backtrack, grouping every run of non-matching tokens between two matches (or an array
    /// boundary) into one hunk. Matched tokens themselves are the "anchor" — never emitted as part
    /// of a hunk; each hunk records whether it is actually flanked by such a match on either side.
    static func replacementHunks(old: [String], new: [String]) -> [ReplacementHunk] {
        let n = old.count
        let m = new.count
        guard n > 0 || m > 0 else { return [] }
        // One flat, row-major `[Int]` allocation instead of `n + 1` separate `[Int]` row arrays —
        // same values, same access pattern (`lengths[i][j]` below becomes `lengths[i * width + j]`
        // via the two helpers), just one contiguous buffer instead of n+1 heap allocations. No
        // change to the algorithm or its output.
        let width = m + 1
        var lengths = Array(repeating: 0, count: (n + 1) * width)
        func length(_ i: Int, _ j: Int) -> Int { lengths[i * width + j] }
        func setLength(_ i: Int, _ j: Int, _ value: Int) { lengths[i * width + j] = value }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                setLength(i, j, old[i] == new[j] ? length(i + 1, j + 1) + 1 : max(length(i + 1, j), length(i, j + 1)))
            }
        }

        var hunks: [ReplacementHunk] = []
        var pendingOld: [String] = []
        var pendingNew: [String] = []
        var hasSeenMatch = false
        var pendingHasLeftAnchor = false
        func flush(hasRightAnchor: Bool) {
            guard !pendingOld.isEmpty || !pendingNew.isEmpty else { return }
            hunks.append(ReplacementHunk(oldTokens: pendingOld, newTokens: pendingNew, hasLeftAnchor: pendingHasLeftAnchor, hasRightAnchor: hasRightAnchor))
            pendingOld = []
            pendingNew = []
        }

        var i = 0
        var j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                flush(hasRightAnchor: true)
                hasSeenMatch = true
                i += 1
                j += 1
            } else {
                if pendingOld.isEmpty && pendingNew.isEmpty { pendingHasLeftAnchor = hasSeenMatch }
                if length(i + 1, j) >= length(i, j + 1) {
                    pendingOld.append(old[i])
                    i += 1
                } else {
                    pendingNew.append(new[j])
                    j += 1
                }
            }
        }
        if (i < n || j < m) && pendingOld.isEmpty && pendingNew.isEmpty { pendingHasLeftAnchor = hasSeenMatch }
        while i < n { pendingOld.append(old[i]); i += 1 }
        while j < m { pendingNew.append(new[j]); j += 1 }
        flush(hasRightAnchor: false)
        return hunks
    }

    /// Classic O(n·m) edit distance — `old`/`new` are single short words here, never whole
    /// transcripts, so the table is tiny.
    static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        // Symmetric empty-argument guard: `!aChars.isEmpty` alone left `1...bChars.count` to be
        // constructed with `bChars.count == 0` whenever `a` was non-empty and `b` was empty —
        // `ClosedRange` traps on a range with `lowerBound > upperBound` (`1...0`). Never reachable
        // in production today (`candidates(transcript:refined:)` only calls this after both words
        // already passed `minTermLength`), but a direct unit test of the empty-argument case
        // crashed without this. See Codex finding (VocabularyMiner.swift:160).
        guard !bChars.isEmpty else { return aChars.count }
        guard !aChars.isEmpty else { return bChars.count }
        var previous = Array(0...bChars.count)
        var current = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                current[j] = aChars[i - 1] == bChars[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
