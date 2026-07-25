import Testing
@testable import FreeTalker

/// Pure-logic coverage for `Insertion.extractEditedReplacement` (BRAINSTORM_CORRECTION_LOOP.md
/// signal C's diff extraction): confined strictly to the range the app itself inserted — a
/// prefix/suffix-preservation check against the SAME baseline+anchor `RecentInsertionStore`
/// already captured, not a new diff algorithm. `nonisolated static` value computation, no AX/CGEvent.
@Suite struct InsertionEditedReplacementTests {
    private static func utf16(_ s: String) -> [UInt16] { Array(s.utf16) }
    private static func str(_ u: [UInt16]) -> String { String(utf16CodeUnits: u, count: u.count) }

    @Test func editedWordInsideTheInsertedRangeIsExtracted() {
        let baseline = Self.utf16("Hi João, how are you")
        let anchor = 3 // "João" starts right after "Hi "
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("Hi Joel, how are you")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "Joel")
    }

    @Test func untouchedDocumentReturnsTheOriginalLedgerText() {
        let baseline = Self.utf16("Hi João, how are you")
        let anchor = 3
        let ledgerLength = Self.utf16("João").count

        let result = Insertion.extractEditedReplacement(
            current: baseline, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "João")
    }

    @Test func editOutsideThePrefixInvalidatesTheExtraction() {
        // The user edited "Hi" -> "Hey", not the inserted word — the prefix no longer matches
        // baseline, so this must refuse rather than guess.
        let baseline = Self.utf16("Hi João, how are you")
        let anchor = 3
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("Hey João, how are you")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result == nil)
    }

    @Test func editOutsideTheSuffixInvalidatesTheExtraction() {
        let baseline = Self.utf16("Hi João, how are you")
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
        let baseline = Self.utf16("Hi João, how are you today")
        let anchor = 3
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("x")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result == nil)
    }

    @Test func negativeAnchorIsRefused() {
        let baseline = Self.utf16("Hi João, how are you")
        let result = Insertion.extractEditedReplacement(
            current: baseline, baseline: baseline, ledgerLength: 4, anchor: -1
        )
        #expect(result == nil)
    }

    @Test func anchorPlusLedgerLengthPastBaselineEndIsRefused() {
        // A stale/drifted baseline (document shorter than what was recorded) must fail closed.
        let baseline = Self.utf16("short")
        let result = Insertion.extractEditedReplacement(
            current: baseline, baseline: baseline, ledgerLength: 100, anchor: 0
        )
        #expect(result == nil)
    }

    @Test func editedWordAtTheVeryStartWithEmptyPrefixIsExtracted() {
        let baseline = Self.utf16("kubernettes cluster is down")
        let anchor = 0
        let ledgerLength = Self.utf16("kubernettes").count
        let current = Self.utf16("kubernetes cluster is down")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "kubernetes")
    }

    @Test func editedWordAtTheVeryEndWithEmptySuffixIsExtracted() {
        let baseline = Self.utf16("please deploy to kubernettes")
        let anchor = Self.utf16("please deploy to ").count
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
        let baseline = Self.utf16("meet João tomorrow")
        let anchor = 5
        let ledgerLength = Self.utf16("João").count
        let current = Self.utf16("meet João Silva tomorrow")

        let result = Insertion.extractEditedReplacement(
            current: current, baseline: baseline, ledgerLength: ledgerLength, anchor: anchor
        )
        #expect(result.map(Self.str) == "João Silva")
    }
}
