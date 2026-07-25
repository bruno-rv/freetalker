import Testing
@testable import FreeTalker

/// Pure state-machine coverage for `RecentInsertionStore.invalidateAll` (Codex Round 2 finding
/// 5): `AppCoordinator`'s `record:` closure catch block invalidates the store when
/// `LibraryStore.record` throws AFTER the text has already been pasted — the just-posted text has
/// no dictation id to attach to (`pending` alone), but whatever OLDER dictation `current` was
/// still tracking must also stop being offered as a correction target. No AX/CGEvent; `.reset()`
/// isolates this suite from the process-wide singleton's state.
@MainActor
@Suite struct RecentInsertionStoreTests {
    @Test func invalidateAllDiscardsPendingAndAnOlderCurrentTogether() {
        let store = RecentInsertionStore.shared
        store.reset()
        defer { store.reset() }

        let target = InsertionTarget(bundleID: "test.app", pid: 1, focusedElement: nil, window: nil)

        // Dictation A already successfully tracked as `current`.
        store.notePending(.init(target: target, baselineValue: "", anchor: 0, text: "dictation A"))
        store.attachDictationID(1)
        #expect(store.recent()?.dictationID == 1)

        // Dictation B pastes — its snapshot is noted as `pending` — but its `LibraryStore.record`
        // call is about to fail before ever attaching an id.
        store.notePending(.init(target: target, baselineValue: "", anchor: 0, text: "dictation B"))

        store.invalidateAll()

        // Neither B's never-attached pending snapshot NOR A's now-stale `current` may be offered
        // to the next correction signal.
        #expect(store.recent() == nil)
    }

    /// `invalidateAll` must not resurrect a `current` a later, unrelated insertion has already
    /// established — mirrors the `generation`-guarded proactive-expiry contract `scheduleExpiry`
    /// already relies on elsewhere in this type.
    @Test func invalidateAllOnAnAlreadySupersededStoreIsANoOpOnTheNewerCurrent() {
        let store = RecentInsertionStore.shared
        store.reset()
        defer { store.reset() }

        let target = InsertionTarget(bundleID: "test.app", pid: 1, focusedElement: nil, window: nil)
        store.notePending(.init(target: target, baselineValue: "", anchor: 0, text: "dictation A"))
        store.attachDictationID(1)
        store.invalidateAll()
        #expect(store.recent() == nil)

        // A later, independent insertion tracks fine after the invalidation.
        store.notePending(.init(target: target, baselineValue: "", anchor: 0, text: "dictation C"))
        store.attachDictationID(3)
        #expect(store.recent()?.dictationID == 3)
    }
}
