import Foundation

/// The single genuine gap BRAINSTORM_CORRECTION_LOOP.md identifies: `Insertion` pastes text into
/// the target app and immediately forgets what it inserted and where. `RecentInsertion` retains
/// exactly that — for one bounded window, for the MOST RECENT dictation only (correcting older
/// history is explicitly out of scope; see BRAINSTORM's "Out of scope" table) — so the three
/// correction signals (hotkey panel, spoken correction, edit-watcher) all have one shared place to
/// ask "what did we just insert, and where."
///
/// `baselineValue`/`anchor` are the SAME shape `LiveInsertionSession`/`Insertion.
/// documentMatchesBaselinePlusLedger` already use for streaming: the target element's full value
/// immediately BEFORE the insertion, and the UTF-16 offset the inserted text was placed at. A
/// correction signal verifies drift by checking the CURRENT document against
/// `baseline[0..<anchor] + text + baseline[anchor...]` — literally the same pure invariant
/// streaming's finalize-time readback already proves, not a second implementation of it.
struct RecentInsertion {
    let dictationID: Int64
    let target: InsertionTarget
    /// Exactly what was placed in the document — the refined text for a plain paste, or the
    /// final live-streamed text for a streaming Recording (see `AppCoordinator.
    /// liveStreamingInsertClosure`). Never the raw ledger left behind by a `.clipboardOnly`
    /// streaming outcome — that text was never verified as actually sitting in the document, so
    /// no `RecentInsertion` is recorded for it at all (see call sites).
    let text: String
    let baselineValue: String
    let anchor: Int
    let insertedAt: Date
}

// `InsertionTarget` holds `AXUIElement?`, which isn't `Equatable` — matches `SelectionSnapshot`
// (same shape, same reason) not conforming either. Tests compare the fields that matter.

/// Owns the single most-recent `RecentInsertion`, plus the write-side handshake that assembles
/// one: `notePending` runs at the moment of insertion (before the dictation's row id exists —
/// `LibraryStore.record` hasn't returned yet), `attachDictationID` runs from `LibraryStore.
/// onDictationRecorded` immediately after (see `AppCoordinator`'s wiring of that closure) to
/// stamp the id onto the pending snapshot. Splitting it this way avoids threading the row id
/// back through `processDictation`'s `record:` closure (which every existing call site — and 17
/// tests — already treats as `Void`-returning); the pending slot is always either promoted to
/// `current` by the very next `onDictationRecorded` firing (same dictation) or explicitly cleared
/// by the call site that didn't produce a trackable insertion, so a stale pending can never
/// attach itself to an unrelated LATER dictation's id.
@MainActor
final class RecentInsertionStore {
    static let shared = RecentInsertionStore()
    private init() {}

    /// Bounded window (BRAINSTORM_CORRECTION_LOOP.md requirement 1): past this, `recent()` stops
    /// offering the insertion for correction even though `current` is still technically in memory
    /// — matches "correcting the most recent dictation" being an in-the-moment action, not a
    /// standing offer.
    static let window: TimeInterval = 10 * 60

    struct Pending {
        let target: InsertionTarget
        let baselineValue: String
        let anchor: Int
        let text: String
    }

    private(set) var current: RecentInsertion?
    private var pending: Pending?

    func notePending(_ pending: Pending) {
        self.pending = pending
    }

    func clearPending() {
        pending = nil
    }

    /// Promotes `pending` to `current` now that its dictation has a row id. A no-op if nothing is
    /// pending (paste failed, drift prevented a snapshot, or a prior `clearPending()` already ran
    /// for this dictation) — `onDictationRecorded` still fires in that case, but there is nothing
    /// to attach.
    func attachDictationID(_ dictationID: Int64, now: Date = Date()) {
        guard let pending else { return }
        current = RecentInsertion(
            dictationID: dictationID, target: pending.target, text: pending.text,
            baselineValue: pending.baselineValue, anchor: pending.anchor, insertedAt: now
        )
        self.pending = nil
    }

    /// The current insertion, only if still inside the bounded window. `now:` is injectable for
    /// tests.
    func recent(now: Date = Date()) -> RecentInsertion? {
        guard let current, now.timeIntervalSince(current.insertedAt) <= Self.window else { return nil }
        return current
    }

    /// Test-only reset — production code never needs to clear `current` directly (a new
    /// insertion simply replaces it).
    func reset() {
        current = nil
        pending = nil
    }
}
