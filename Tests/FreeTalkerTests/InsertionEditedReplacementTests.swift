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

    // MARK: - Codex Round 2 finding 3: `rangeLimitedEditedReplacement`'s 32-char delta bound

    @Test func boundedEditedLengthAllowsGrowthUpToTheBound() {
        // A genuine correction growing the inserted text by up to 32 UTF-16 units is still read.
        #expect(Insertion.boundedEditedLength(currentLength: 132, baselineLength: 100, ledgerLength: 4) == 36)
        #expect(Insertion.boundedEditedLength(currentLength: 100, baselineLength: 100, ledgerLength: 4) == 4)
    }

    @Test func boundedEditedLengthFailsClosedPastThePositiveBound() {
        // Codex Round 2 finding 3's core regression: the user kept typing AFTER the dictation,
        // never touching the inserted range at all — `delta` keeps growing with every character,
        // and once it exceeds the bound this must refuse to read rather than reading the
        // dictation plus everything typed after it.
        #expect(Insertion.boundedEditedLength(currentLength: 100 + Insertion.editWatcherDeltaBound, baselineLength: 100, ledgerLength: 4) != nil)
        #expect(Insertion.boundedEditedLength(currentLength: 100 + Insertion.editWatcherDeltaBound + 1, baselineLength: 100, ledgerLength: 4) == nil)
    }

    @Test func boundedEditedLengthFailsClosedPastTheNegativeBound() {
        // A shrink past the bound (something well outside the tracked range was deleted) fails
        // closed exactly the same way growth does.
        #expect(Insertion.boundedEditedLength(currentLength: 100 - Insertion.editWatcherDeltaBound, baselineLength: 100, ledgerLength: 4) != nil)
        #expect(Insertion.boundedEditedLength(currentLength: 100 - Insertion.editWatcherDeltaBound - 1, baselineLength: 100, ledgerLength: 4) == nil)
    }

    @Test func boundedEditedLengthNeverShrinksBelowTheOriginalLedgerLength() {
        // A negative delta within bounds still requests at least `ledgerLength` characters (never
        // shrunk below it) — see `boundedEditedLength`'s doc comment for why.
        #expect(Insertion.boundedEditedLength(currentLength: 95, baselineLength: 100, ledgerLength: 4) == 4)
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
