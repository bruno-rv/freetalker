import Testing
@testable import FreeTalker

/// Pure-logic coverage for `Insertion.extractEditedReplacement` (BRAINSTORM_CORRECTION_LOOP.md
/// signal C's diff extraction): confined strictly to the range the app itself inserted — a
/// prefix/suffix-preservation check against the SAME baseline+anchor `RecentInsertionStore`
/// already captured, not a new diff algorithm. `nonisolated static` value computation, no AX/CGEvent.
///
/// Codex finding 5: `baseline` here is always the PRE-insertion value (matching what production
/// actually stores in `RecentInsertion.baselineValue` — captured by `Insertion.
/// captureCorrectionAnchor` BEFORE the paste posts) — it never contains the ledger text itself.
/// Every fixture below reflects that; the pre-fix version of these tests passed POST-insertion
/// baselines (baseline already containing the ledger) and so agreed with the bug rather than
/// catching it.
@Suite struct InsertionEditedReplacementTests {
    private static func utf16(_ s: String) -> [UInt16] { Array(s.utf16) }
    private static func str(_ u: [UInt16]) -> String { String(utf16CodeUnits: u, count: u.count) }

    @Test func editedWordInsideTheInsertedRangeIsExtracted() {
        // Pre-insertion baseline: "João" was never in the document until the app inserted it.
        let baseline = Self.utf16("Hi , how are you")
        let anchor = 3 // "João" was spliced in right after "Hi "
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("Hi Joel, how are you")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "Joel")
    }

    @Test func untouchedDocumentReturnsTheOriginalLedgerText() {
        let baseline = Self.utf16("Hi , how are you")
        let anchor = 3
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("Hi João, how are you") // baseline with the ledger spliced in, untouched

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "João")
    }

    @Test func editOutsideThePrefixInvalidatesTheExtraction() {
        // The user edited "Hi" -> "Hey", not the inserted word — the prefix no longer matches
        // baseline, so this must refuse rather than guess.
        let baseline = Self.utf16("Hi , how are you")
        let anchor = 3
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("Hey João, how are you")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result == nil)
    }

    @Test func editOutsideTheSuffixInvalidatesTheExtraction() {
        let baseline = Self.utf16("Hi , how are you")
        let anchor = 3
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("Hi João, how are u")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result == nil)
    }

    @Test func currentShorterThanPrefixPlusSuffixIsRefusedNotUnderflowed() {
        // Guards the `current.count >= prefix.count + suffix.count` check — without it this would
        // crash on `current.count - suffix.count` underflowing.
        let baseline = Self.utf16("Hi , how are you today")
        let anchor = 3
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("x")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result == nil)
    }

    @Test func negativeAnchorIsRefused() {
        let baseline = Self.utf16("Hi , how are you")
        let result = Insertion.extractEditedReplacement(
            current: baseline, baseline: baseline, ledgerLength: 4, anchor: -1
        )
        #expect(result == nil)
    }

    @Test func anchorPastBaselineEndIsRefused() {
        // A stale/drifted baseline (document shorter than what was recorded) must fail closed.
        let baseline = Self.utf16("short")
        let result = Insertion.extractEditedReplacement(
            current: baseline, baseline: baseline, ledgerLength: 100, anchor: baseline.count + 1
        )
        #expect(result == nil)
    }

    @Test func editedWordAtTheVeryStartWithEmptyPrefixIsExtracted() {
        // Codex finding 5's core regression: an insertion at offset 0 — anchor 0, empty prefix —
        // must still be extractable, not refused just because there's no prefix to anchor on.
        let baseline = Self.utf16(" cluster is down")
        let anchor = 0
        let ledgerLength = Self.utf16("kubernettes").count
        let current = Self.utf16("kubernetes cluster is down")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "kubernetes")
    }

    @Test func editedWordAtTheVeryEndWithEmptySuffixIsExtracted() {
        // Codex finding 5's core regression: an END-OF-FIELD insertion — anchor == baseline.count,
        // empty suffix — previously ALWAYS failed the (buggy) `anchor + ledgerLength <=
        // baseline.count` guard, since a pre-insertion baseline never contains the ledger at all.
        let baseline = Self.utf16("please deploy to ")
        let anchor = baseline.count
        let ledgerLength = Self.utf16("kubernettes").count
        let current = Self.utf16("please deploy to kubernetes")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "kubernetes")
    }

    @Test func replacementCanGrowLongerThanTheOriginalLedgerText() {
        // The user typed MORE than what was there — still confined to between the (unchanged)
        // prefix and suffix, so this must still extract cleanly, not just same-length edits.
        let baseline = Self.utf16("meet  tomorrow")
        let anchor = 5
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("meet João Silva tomorrow")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "João Silva")
    }

    // MARK: - Codex Round 2 finding 3 / Round 3 finding 3: `rangeLimitedEditedReplacement`'s
    // 32-char delta bound, against the CORRECTED (pre-insertion) baseline arithmetic.
    //
    // Round 3 finding 3: `baselineLength` is always the PRE-insertion field length — production
    // never observes `currentLength == baselineLength` for an untouched insertion (that would
    // mean the inserted ledger simply vanished). Every fixture below derives `currentLength` the
    // way production actually would: `baselineLength + ledgerLength` for "untouched," adjusted by
    // whatever the simulated edit changed — never a bare `baselineLength` restated as if nothing
    // was ever inserted.

    @Test func boundedEditedLengthAllowsGrowthUpToTheBound() {
        // A genuine correction growing the inserted text by up to 32 UTF-16 units is still read.
        // baseline 100, ledger 4 -> untouched current length is 104; +32 growth is 136.
        #expect(Insertion.boundedEditedLength(currentLength: 136, baselineLength: 100, ledgerLength: 4) == 36)
        #expect(Insertion.boundedEditedLength(currentLength: 104, baselineLength: 100, ledgerLength: 4) == 4)
    }

    @Test func boundedEditedLengthFailsClosedPastThePositiveBound() {
        // Codex Round 2 finding 3's core regression: the user kept typing AFTER the dictation,
        // never touching the inserted range at all — `delta` keeps growing with every character,
        // and once it exceeds the bound this must refuse to read rather than reading the
        // dictation plus everything typed after it.
        #expect(Insertion.boundedEditedLength(currentLength: 100 + 4 + Insertion.editWatcherDeltaBound, baselineLength: 100, ledgerLength: 4) != nil)
        #expect(Insertion.boundedEditedLength(currentLength: 100 + 4 + Insertion.editWatcherDeltaBound + 1, baselineLength: 100, ledgerLength: 4) == nil)
    }

    @Test func boundedEditedLengthFailsClosedPastTheNegativeBound() {
        // A shrink past the bound (something well outside the tracked range was deleted) fails
        // closed exactly the same way growth does. Uses a ledger (40) longer than the bound (32)
        // so the boundary itself — not the separate `editedLength >= 0` floor — is what's tested.
        #expect(Insertion.boundedEditedLength(currentLength: 100 + 40 - Insertion.editWatcherDeltaBound, baselineLength: 100, ledgerLength: 40) != nil)
        #expect(Insertion.boundedEditedLength(currentLength: 100 + 40 - Insertion.editWatcherDeltaBound - 1, baselineLength: 100, ledgerLength: 40) == nil)
    }

    @Test func boundedEditedLengthAllowsTheEditedRegionToShrinkBelowTheOriginalLedgerLength() {
        // Round 3 finding 3 fix: with the corrected delta (measured against baseline + ledger,
        // not baseline alone), a genuine shrink WITHIN the tracked range — a 4-character ledger
        // corrected down to a 1-character region — is requested at its true, shorter length, not
        // clamped back up to `ledgerLength`. The old clamp (`max(0, delta)`) existed only to
        // compensate for the wrong delta baseline; with the fix there's no reason to over-read
        // past the edit.
        #expect(Insertion.boundedEditedLength(currentLength: 100 + 1, baselineLength: 100, ledgerLength: 4) == 1)
    }

    @Test func boundedEditedLengthTreatsAnUntouchedInsertionAsZeroDelta() {
        // Round 3 finding 3's concrete failure case: baseline "Hello dog", ledger "cat" inserted
        // before "dog" (anchor 6, ledgerLength 3) — an untouched field becomes "Hello catdog"
        // (length 12 = baseline 9 + ledger 3). The old (buggy) formula computed
        // `delta = currentLength - baselineLength = 3`, requesting `ledgerLength + delta = 6`
        // characters ("catdog") and misreading the untouched insertion as an edit. The corrected
        // formula must report exactly `ledgerLength` (3) — nothing changed.
        let baselineLength = "Hello dog".utf16.count
        let ledgerLength = "cat".utf16.count
        let currentLength = "Hello catdog".utf16.count
        #expect(Insertion.boundedEditedLength(currentLength: currentLength, baselineLength: baselineLength, ledgerLength: ledgerLength) == ledgerLength)
    }

    @Test func middleInsertionDoesNotAbsorbPreExistingSuffixIntoTheEditedRegion() {
        // Codex finding 5's middle-insertion regression: with the (buggy) post-insertion
        // treatment, `suffix = baseline[(anchor + ledgerLength)...]` sliced INTO the pre-existing
        // suffix content by `ledgerLength` characters it never should have consumed, silently
        // absorbing real, untouched suffix text into what it reported as "edited." The
        // pre-insertion baseline fix keeps the suffix exactly `baseline[anchor...]` — "tomorrow"
        // stays outside the extraction, untouched, even though nothing here was edited at all.
        let baseline = Self.utf16("meet  tomorrow")
        let anchor = 5
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("meet João tomorrow") // untouched: ledger spliced in verbatim

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "João")
    }
}
