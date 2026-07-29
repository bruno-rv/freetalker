import AppKit
import ApplicationServices
import CoreGraphics

/// Identity of the frontmost app (and, best-effort, its focused element/window) snapshotted at
/// key-up — before the async transcribe/post-process work — so the paste-time check can detect
/// drift stronger than bundle id alone. Bundle id alone only catches the user switching to a
/// *different app*; it misses switching *within the same app* (a different Slack channel, a
/// different Mail draft, a different browser tab) while dictation is still processing, which
/// would land the paste in the wrong field. `focusedElement`/`window` are best-effort — some
/// apps are AX-opaque (deny AX queries) and leave both nil; that degraded case is handled
/// explicitly by `Insertion.ElementComparison.unavailable`, not silently ignored. Snapshotting
/// stays in `Insertion` (which owns all the AX machinery) — `AppCoordinator` only stores and
/// forwards the result through the pipeline. See Round 2 Codex finding: same-app target drift.
struct InsertionTarget {
    let bundleID: String?
    let pid: pid_t
    let focusedElement: AXUIElement?
    let window: AXUIElement?
    /// `kAXDocumentAttribute`, snapshotted alongside `focusedElement`/`window` — Round 3 fix: this
    /// used to also govern `compareElements`/`streamingSafeElement` (every insertion path), which
    /// was wrong. Chromium exposes this attribute as the tab's page URL, so it changes on any
    /// `history.replaceState` — not a document identity — and Round 3 finding 2 further showed a
    /// URL match doesn't even prove identity (a duplicated tab shares the same URL). It is now
    /// consulted ONLY by `SelectionAccess`'s correction-fallback revalidation
    /// (`SelectionSnapshot.correctionDictationID != nil` — see `CorrectionTargeting.
    /// selectRecentInsertion`), never by `Insertion.insert`, `streamingSafeElement`, or ordinary
    /// manual Voice Edit, all of which behave exactly as `main`. `nil` when the app doesn't expose
    /// the attribute at all.
    let document: String?

    init(bundleID: String?, pid: pid_t, focusedElement: AXUIElement?, window: AXUIElement?, document: String? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.focusedElement = focusedElement
        self.window = window
        self.document = document
    }
}

/// `Insertion.insert`'s structured failure reason (PLAN.md F2.4). Only `axDenied` is
/// permission-class — `targetDrift`/`noFocusedElement`/`pasteFailed` are expected steady-state
/// outcomes (a drifted target, an empty focus target, a CGEvent post glitch), not permission
/// regressions, so Permission Diagnosis recompute is gated on `isPermissionClassFailure`.
enum InsertionFailureReason: Equatable, Sendable {
    case axDenied
    case targetDrift
    case noFocusedElement
    case pasteFailed
}

/// Replaces the bare `Bool` `Insertion.insert` used to return: `posted` preserves the exact
/// truthiness every existing caller already branches on, `failureReason` adds the classification
/// PLAN.md F2.4 asks for without changing that truthiness at any return point.
struct InsertionOutcome: Equatable, Sendable {
    let posted: Bool
    let failureReason: InsertionFailureReason?

    static let success = InsertionOutcome(posted: true, failureReason: nil)
    static func failure(_ reason: InsertionFailureReason) -> InsertionOutcome {
        InsertionOutcome(posted: false, failureReason: reason)
    }

    var isPermissionClassFailure: Bool {
        failureReason == .axDenied
    }
}

enum Insertion {
    /// Compares a snapshotted focused element/window against what's focused now. `.unavailable`
    /// covers both "no snapshot was taken at all" and "the snapshot app was AX-opaque, so
    /// neither element nor window were obtainable" — both fall back to bundle+pid identity
    /// (checked separately) instead of blocking the paste.
    enum ElementComparison {
        case match
        case mismatch
        case unavailable
    }

    /// Snapshots the frontmost app's identity for a later paste-time comparison — bundle id,
    /// pid, and (best-effort) the currently focused AXUIElement and its AXWindow. Call at
    /// key-up, before any `await`. Returns nil only when there's no frontmost app to snapshot.
    static func snapshotTarget(app: NSRunningApplication?) -> InsertionTarget? {
        guard let app else { return nil }
        let element = focusedElement(for: app)
        let window = element.flatMap(windowElement(for:))
        let document = documentDiscriminator(element: element, window: window)
        return InsertionTarget(bundleID: app.bundleIdentifier, pid: app.processIdentifier, focusedElement: element, window: window, document: document)
    }

    /// Returns true if a synthetic ⌘V was posted. Skips posting (leaving the text on the
    /// pasteboard for a manual paste) if the frontmost app reports no focused UI element, since
    /// pasting into nothing would silently strand the dictated text after restoring the old
    /// clipboard. On CGEvent post failure, the text is also left on the pasteboard.
    ///
    /// `target`, when non-nil, is the identity snapshotted at key-up (see `InsertionTarget`). If
    /// the frontmost app, its pid, or (where obtainable) its focused element/window have changed
    /// by the time we're about to paste, synthesizing ⌘V could paste into the wrong app's — or
    /// the same app's wrong — focused field, so this skips the paste and leaves the text on the
    /// pasteboard instead, same as the no-focused-element case. A nil `target` (e.g.
    /// `AppCoordinator.reprocess`, which has no frontmost-app snapshot for a historical
    /// re-process) preserves the pre-fix behavior of always pasting, UNLESS `strict` is set. See
    /// Codex finding: paste-target drift / same-app target drift.
    ///
    /// `strict`, when true, closes off that nil-target permissiveness: a nil (or otherwise
    /// unverifiable) target is treated as drifted rather than as "nothing to contradict, so
    /// paste anyway." Every existing caller keeps the permissive default (`false`) — this is
    /// opt-in per call site, not a global behavior change. See Codex finding: unverified panel
    /// paste reaching the permissive nil-target branch.
    ///
    /// `restoresPasteboard: false` suppresses the timed restore below. Only the two-phase
    /// insertion path passes it: its two pastes can land less than the restore delay apart, so
    /// phase 2 would otherwise snapshot phase 1's raw transcript and "restore" *that* over the
    /// user's clipboard. Those callers snapshot once, before phase 1, and restore once, after
    /// phase 2.
    @discardableResult
    static func insert(
        _ text: String, target: InsertionTarget? = nil, strict: Bool = false,
        restoresPasteboard: Bool = true
    ) -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        let currentApp = NSWorkspace.shared.frontmostApplication
        let currentBundleID = currentApp?.bundleIdentifier
        let currentElement = currentApp.flatMap(focusedElement(for:))
        let currentWindow = currentElement.flatMap(windowElement(for:))
        // No target snapshotted at all -> nothing to contradict, stays permissive (matches the
        // hasTarget: false branch of shouldSynthesizePaste below). This is distinct from "a
        // target was snapshotted but its bundleID was nil" — see Round 3 Codex finding: paste-
        // target drift with nil bundle id.
        let pidMatch = target.map { $0.pid == currentApp?.processIdentifier } ?? true
        let elementComparison = compareElements(snapshot: target, currentElement: currentElement, currentWindow: currentWindow)

        if let reason = classifyPreflightFailure(
            hasTarget: target != nil,
            snapshotBundleID: target?.bundleID,
            currentBundleID: currentBundleID,
            pidMatch: pidMatch,
            elementComparison: elementComparison,
            hasEditableFocusedElement: isEditableFocusedElement(currentElement),
            accessibilityTrusted: Permissions.isAccessibilityTrusted(),
            strict: strict
        ) {
            // Either identity drifted since the snapshot (leave the text on the pasteboard for
            // a manual paste rather than pasting into whatever now has focus), or there's no
            // focused element to paste into — see Round 2 Codex finding 1.
            return .failure(reason)
        }

        let posted = postCommandV()

        if posted, restoresPasteboard {
            schedulePasteboardRestore(savedItems, changeCountAfterWrite: changeCountAfterWrite)
        }
        return posted ? .success : .failure(.pasteFailed)
    }

    private static func pasteboardSnapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        } ?? []
    }

    /// Timed restore: deliberate, logged decision — a residual race remains if the target app is
    /// slow to read the pasteboard, but a completion signal isn't available via public API. 1.0s
    /// (up from 0.3s) narrows the window; the changeCount guard still skips the restore if
    /// anything else wrote to the pasteboard first. See Round 1 Codex finding 5 / Round 2 Codex
    /// finding 2.
    /// ponytail: timed restore, residual race accepted for personal use + upgrade path: skip
    /// restore option in Settings.
    private static func schedulePasteboardRestore(
        _ savedItems: [[NSPasteboard.PasteboardType: Data]],
        changeCountAfterWrite: Int
    ) {
        // `NSPasteboard.general` is re-read inside the closure rather than captured: it's the same
        // single system pasteboard either way, and capturing the object would send a
        // task-isolated reference into a main-actor closure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCountAfterWrite else { return }
            restore(savedItems, to: pasteboard)
        }
    }

    /// Pure classification of `insert`'s pre-paste failure reason (PLAN.md F2.4), factored out of
    /// `insert` so it's testable without a live AX/pasteboard environment — same style as
    /// `shouldSynthesizePaste` below. Returns nil when the paste should proceed.
    nonisolated static func classifyPreflightFailure(
        hasTarget: Bool,
        snapshotBundleID: String?,
        currentBundleID: String?,
        pidMatch: Bool,
        elementComparison: ElementComparison,
        hasEditableFocusedElement: Bool,
        accessibilityTrusted: Bool,
        strict: Bool = false
    ) -> InsertionFailureReason? {
        guard shouldSynthesizePaste(
            hasTarget: hasTarget,
            snapshotBundleID: snapshotBundleID,
            currentBundleID: currentBundleID,
            pidMatch: pidMatch,
            elementComparison: elementComparison,
            strict: strict
        ) else {
            return .targetDrift
        }
        guard hasEditableFocusedElement else {
            // No focused element is the visible symptom both of a genuinely empty focus target
            // and of Accessibility not being trusted (the AX queries in `insert` silently return
            // nil either way) — disambiguate since only the latter is Permission Diagnosis-
            // relevant.
            return accessibilityTrusted ? .noFocusedElement : .axDenied
        }
        return nil
    }

    nonisolated static func shouldSynthesizePaste(
        hasTarget: Bool,
        snapshotBundleID: String?,
        currentBundleID: String?,
        pidMatch: Bool = true,
        elementComparison: ElementComparison = .unavailable,
        strict: Bool = false
    ) -> Bool {
        // `strict` callers (e.g. the Dictation History panel — see `AppCoordinator.
        // insertFromHistoryPanel`) always have — or explicitly lack — a snapshotted target, so a
        // nil target there is exactly as unverifiable as a nil bundle id below: never paste. Non-
        // strict callers (ordinary dictation) have no frontmost-app snapshot to compare against
        // at all, so a nil target there has nothing to contradict and stays permissive.
        guard hasTarget else { return !strict }
        // A snapshotted target with no bundle id at all has no verifiable identity — `pidMatch`
        // alone doesn't substitute for it (pids are reused after a process exits, so a matching
        // pid doesn't prove it's still the same app instance), and an `.unavailable` element
        // comparison gives no information either. Treat this as drifted rather than accept an
        // unverified paste. See Round 4 Codex finding: nil-bundle-id identity bypass (PID reuse).
        guard let snapshotBundleID else { return false }
        guard let currentBundleID, snapshotBundleID == currentBundleID else { return false }
        guard pidMatch else { return false }
        switch elementComparison {
        case .mismatch: return false
        case .match: return true
        // Matching bundle id/pid only proves it's the same APP, not the same focused field — a
        // same-app focus change (e.g. the user tabbed to a different field, or a new window took
        // focus) between snapshot and paste is exactly as unverifiable as the nil-bundle-id case
        // above when the element comparison itself is AX-opaque. Non-strict (ordinary dictation)
        // callers keep the pre-fix permissive behavior since they have no better signal to fall
        // back on; `strict` callers (the History panel, replaying old text into whatever is
        // frontmost right now) must never paste on an unverified identity. See P1 finding: strict
        // mode accepted `.unavailable` and could paste history text into the wrong field after a
        // same-app focus change.
        case .unavailable: return !strict
        }
    }

    // MARK: - Streaming ASR live-typing safety (Codex findings 1, 2, 3, 4, 5)
    //
    // These are new, streaming-specific checks — not a rewrite of the pre-existing
    // `AccessibilityContext`/`SystemAccessibilityNodeAdapter.isSecure`, which compares
    // `kAXRoleAttribute` against `"AXSecureTextField"` (that's a SUBROLE, not a role, so it never
    // actually fires for a password field exposing role `AXTextField` + secure subrole). That
    // helper is unchanged here — it's identical to `main` and still used elsewhere for read-only
    // context capture — but live typing is a new, more dangerous consumer, so it gets its own
    // correct check rather than inheriting the bug. See DEFERRED-FINDINGS.md.

    /// Result of `streamingStartGate`: whether streaming may begin at all for a Recording.
    struct StreamingStartGate {
        let hasCollapsedSelection: Bool
        let isSecure: Bool
    }

    /// Snapshot used ONCE, at Recording start, to decide whether live streaming may begin at all
    /// (Codex findings 1, 4): the focused field must have a collapsed (empty) selection — typing
    /// over a real selection would silently destroy it with no way to restore it on Cancel — and
    /// must not be secure (subrole + protected content). Both read from the SAME element. `nil`
    /// (AX untrusted, no focused element, or an unreadable selection range) fails closed to "not
    /// safe to stream" — an unreadable selection can't be proven collapsed.
    @MainActor
    static func streamingStartGate(pid: pid_t) -> StreamingStartGate? {
        guard Permissions.isAccessibilityTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let element = focusedRef as! AXUIElement // swiftlint:disable:this force_cast
        guard let range = selectedRange(of: element) else { return nil }
        return StreamingStartGate(hasCollapsedSelection: range.length == 0, isSecure: isSecureForStreaming(element))
    }

    /// One fresh AX read of `target`'s focused element, used immediately before every act that
    /// touches the target app during a live-streaming Recording — typing a partial, or
    /// backspacing/pasting at finalize (Codex finding 5: identity and security must be derived
    /// from the same read and re-checked immediately before every write, not once at Recording
    /// start). Identity reuses the exact same drift check `insert(_:target:strict:)` performs at
    /// paste time (bundle id + pid + best-effort focused element/window comparison, always
    /// `strict`) rather than a second, divergent implementation. `nil` (unsafe) covers: AX
    /// untrusted, identity drifted, no focused element, or the focused element is secure/unreadable.
    ///
    /// Round 3 fix: this used to also carve out an exception for a changed `kAXDocumentAttribute`
    /// value via a `ledgerProvenance` parameter. That whole mechanism only existed to compensate
    /// for the document check having been added to this SHARED path in the first place — Chromium
    /// exposes that attribute as the tab's URL, and rewriting it via `history.replaceState` is a
    /// side effect of ordinary typing, not a target switch. The document check itself has moved
    /// to `SelectionAccess`'s correction-fallback-only revalidation (see `InsertionTarget.
    /// document`'s doc comment); this function is identical to `main` again.
    @MainActor
    static func streamingSafeElement(target: InsertionTarget) -> AXUIElement? {
        guard Permissions.isAccessibilityTrusted() else { return nil }
        let currentApp = NSWorkspace.shared.frontmostApplication
        let currentElement = currentApp.flatMap(focusedElement(for:))
        let currentWindow = currentElement.flatMap(windowElement(for:))
        let pidMatch = target.pid == currentApp?.processIdentifier
        let elementComparison = compareElements(snapshot: target, currentElement: currentElement, currentWindow: currentWindow)
        guard shouldSynthesizePaste(
            hasTarget: true,
            snapshotBundleID: target.bundleID,
            currentBundleID: currentApp?.bundleIdentifier,
            pidMatch: pidMatch,
            elementComparison: elementComparison,
            strict: true
        ), let currentElement else { return nil }
        guard !isSecureForStreaming(currentElement) else { return nil }
        return currentElement
    }

    /// One fresh read combining `streamingSafeElement` (identity/security) with a collapsed-
    /// selection and caret-position check, used immediately before EVERY unicode post
    /// (`LiveInsertionSession.receivePartial`) — not just once at Recording start (Codex finding
    /// 2). `expectedCaret`, when non-nil, must equal the CURRENT caret exactly: the anchor
    /// position this session's own first post observed, plus everything typed since (Codex
    /// finding 3 — a readback that only checks text content before *wherever* the caret happens
    /// to be right now can be fooled by an identical run of text elsewhere in the same field; an
    /// absolute caret match closes that gap). `nil` `expectedCaret` is the first-ever post for
    /// this session (ledger still empty) — there is no prior anchor to compare against yet, but
    /// the selection must still be collapsed. Returns the observed caret (to become the anchor on
    /// the caller's first successful post) or nil if anything is unsafe/unreadable/mismatched.
    @MainActor
    static func streamingWriteCaret(target: InsertionTarget, expectedCaret: Int?) -> Int? {
        guard let element = streamingSafeElement(target: target) else { return nil }
        guard let range = selectedRange(of: element), range.length == 0 else { return nil }
        if let expectedCaret, range.location != expectedCaret { return nil }
        return range.location
    }

    /// Whether the current document is EXACTLY `baseline` with `expectedTrailingText` (the
    /// ledger) spliced in at the anchor, AND the caret sits exactly at `expectedCaret` (Codex
    /// finding 3, and finding 2 — see `baseline` below). `expectedCaret` is the session's caret
    /// anchor (captured before its first post) plus everything typed since — an absolute,
    /// session-specific position, not just "immediately before wherever the caret currently is".
    /// UTF-16 offsets throughout (AX's native indexing, matching `NSString`) since grapheme
    /// clusters don't map 1:1 to UTF-16 code units. Requires a collapsed caret (no active
    /// selection) — a real selection at this instant means something else changed the field since
    /// the session last typed into it.
    ///
    /// `baseline` (Codex finding 2) is the field's full value snapshotted alongside this session's
    /// FIRST caret read, before any typing — checking only "does text matching the ledger sit
    /// immediately before a caret that's in the right place" authenticates LOCATION, not
    /// PROVENANCE: pre-existing document text that happens to equal the ledger's content, sitting
    /// at the same offset the user's caret later lands on for any unrelated reason, satisfies that
    /// just as well as this session's own delivered insertion — e.g. the field already contains
    /// "hello" at offset 0, this session's synthesized "hello" at offset 0 is silently swallowed by
    /// the app/IME, and the user later parks the caret at offset 5. Requiring the ENTIRE current
    /// document to equal `baseline` with the ledger spliced in at the anchor — not just the
    /// substring immediately before the caret — proves nothing besides this session's own typing
    /// changed the field since `baseline` was captured.
    static func readbackMatches(element: AXUIElement, expectedTrailingText: String, expectedCaret: Int, baseline: String) -> Bool {
        guard !expectedTrailingText.isEmpty else { return true }
        guard let range = selectedRange(of: element), range.length == 0 else { return false }
        guard range.location == expectedCaret else { return false }
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return false }
        let anchor = expectedCaret - expectedTrailingText.utf16.count
        return documentMatchesBaselinePlusLedger(
            current: Array(text.utf16), baseline: Array(baseline.utf16),
            ledger: Array(expectedTrailingText.utf16), anchor: anchor
        )
    }

    /// Pure reconstruction check (Codex finding 2), factored out of `readbackMatches` so the
    /// provenance invariant is directly unit-testable without a live AX session — same style as
    /// `classifyPreflightFailure`/`shouldSynthesizePaste` above. `current`/`baseline`/`ledger` are
    /// all UTF-16 code units (AX's native indexing); `anchor` is the position in `baseline` where
    /// the ledger was inserted. `anchor` out of `baseline`'s bounds (a caret-anchor arithmetic
    /// impossibility) fails closed.
    nonisolated static func documentMatchesBaselinePlusLedger(
        current: [UInt16], baseline: [UInt16], ledger: [UInt16], anchor: Int
    ) -> Bool {
        guard anchor >= 0, anchor <= baseline.count else { return false }
        let expected = Array(baseline[0..<anchor]) + ledger + Array(baseline[anchor...])
        return current == expected
    }

    /// One fresh read of `target`'s focused element's full current text (Codex finding 2), meant
    /// to be captured once, immediately alongside this session's first caret read (before any
    /// typing) — see `readbackMatches`'s `baseline` parameter. `nil` (AX untrusted, drifted, or
    /// unreadable) fails the caller closed: without a baseline, no later delete can ever be proven
    /// to be this session's own text rather than content that happened to already be there.
    @MainActor
    static func streamingBaselineValue(target: InsertionTarget) -> String? {
        guard let element = streamingSafeElement(target: target) else { return nil }
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String else { return nil }
        return text
    }

    /// Correction Loop signal C (edit-watcher, `EditWatcher`): given the document's CURRENT value
    /// and `baseline` — the field's value immediately BEFORE the insertion (the SAME PRE-insertion
    /// snapshot `RecentInsertion.baselineValue`/`documentMatchesBaselinePlusLedger` use; it never
    /// contains the ledger itself) plus the anchor it was spliced in at — returns whatever now
    /// sits BETWEEN the unchanged prefix/suffix — i.e. exactly what the user edited the app's own
    /// inserted text INTO — or `nil` if anything outside that range changed at all. This is the
    /// requirement 5 boundary made concrete: "reads only the range the app itself inserted...
    /// never the rest of the field, never anything typed before or after." A change to the prefix
    /// or suffix (the user edited something ELSE in the same field) fails closed to `nil` rather
    /// than guessing which part moved.
    ///
    /// Codex finding 5: `baseline` was previously (incorrectly) treated as POST-insertion here —
    /// the ONLY caller (`EditWatcher`) always passes the pre-insertion value, so an end-of-field
    /// insertion always failed `anchor + ledgerLength <= baseline.count` (baseline never contained
    /// the ledger, so that bound could never hold once `anchor` reached the pre-insertion length),
    /// and a middle insertion incorrectly absorbed the first `ledgerLength` UTF-16 units of
    /// pre-existing suffix into the "edited" region. `anchor <= baseline.count` (not
    /// `anchor + ledgerLength`) and `baseline[anchor...]` as the suffix match what's actually
    /// stored.
    nonisolated static func extractEditedReplacement(
        current: [UInt16], baseline: [UInt16], ledgerLength: Int, anchor: Int
    ) -> [UInt16]? {
        guard anchor >= 0, ledgerLength >= 0, anchor <= baseline.count else { return nil }
        let prefix = Array(baseline[0..<anchor])
        let suffix = Array(baseline[anchor...])
        guard current.count >= prefix.count + suffix.count else { return nil }
        guard Array(current.prefix(prefix.count)) == prefix else { return nil }
        guard Array(current.suffix(suffix.count)) == suffix else { return nil }
        return Array(current[prefix.count..<(current.count - suffix.count)])
    }

    /// The ONLY AX read `EditWatcher` performs per poll (Codex finding 4): reads `element`'s
    /// character COUNT (`kAXNumberOfCharactersAttribute` — a bare `Int`, no content at all) to
    /// compute where the edited middle region now ends, then reads EXACTLY that middle region via
    /// `kAXStringForRangeParameterizedAttribute` — never the prefix, never the suffix, never the
    /// whole field. The pre-fix implementation read the field's entire `kAXValueAttribute` value
    /// every poll, "materialising the entire field contents" (a confidential document's whole text)
    /// just to confirm a short edit; this reconstructs the same `(anchor, editedLength)` window
    /// `extractEditedReplacement` computes from lengths alone, so the round-trip AX request is
    /// PROVABLY bounded to the range that changed, not merely "current implementation happens not
    /// to read more." A negative computed `editedLength` (the document shrank more than the
    /// tracked prefix+suffix allow for — something outside the watched range changed) fails closed
    /// without reading anything else to find out what. `nil` whenever the parameterized attribute
    /// isn't supported at all (Electron/most web views) — signal C is simply UNAVAILABLE for that
    /// poll rather than ever falling back to an unbounded whole-field read.
    ///
    /// Codex Round 2 finding 3: deriving `editedLength` from the field's CURRENT total length
    /// alone (`currentLength - anchor - suffixLength`) never actually proves the prefix/suffix
    /// are unchanged — at an end-of-field insertion (`suffixLength == 0`) it degenerates to
    /// "current length minus anchor," so the user simply CONTINUING TO TYPE after the dictation
    /// (never touching the inserted range at all) kept inflating `editedLength` forever, and the
    /// next poll read the dictation plus everything typed after it. `boundedEditedLength` bounds
    /// how far the document's total length may have moved from `baseline.count` at all — see its
    /// doc comment — and requests exactly that many characters, never more.
    @MainActor
    static func rangeLimitedEditedReplacement(
        element: AXUIElement, baseline: [UInt16], ledgerLength: Int, anchor: Int
    ) -> [UInt16]? {
        guard anchor >= 0, ledgerLength >= 0, anchor <= baseline.count else { return nil }
        guard let currentLength = numberOfCharacters(element) else { return nil }
        guard let editedLength = boundedEditedLength(
            currentLength: currentLength, baselineLength: baseline.count, ledgerLength: ledgerLength
        ) else { return nil }
        guard let edited = stringForRange(element, location: anchor, length: editedLength) else { return nil }
        return Array(edited.utf16)
    }

    // ponytail: 32-char delta bound keeps the read near the inserted range; a position-stable AX
    // marker design would remove the bound.
    static let editWatcherDeltaBound = 32

    /// Pure bound check (Codex Round 2 finding 3, delta arithmetic corrected by Round 3 finding
    /// 3), factored out of `rangeLimitedEditedReplacement` so it's directly unit-testable without
    /// a live AX session — same style as `documentMatchesBaselinePlusLedger`/
    /// `extractEditedReplacement` above.
    ///
    /// Round 3 finding 3: `baselineLength` is the PRE-insertion field length (the same
    /// pre-insertion snapshot `extractEditedReplacement`'s `baseline` uses — see that doc
    /// comment), so an UNTOUCHED insertion has `currentLength == baselineLength + ledgerLength`,
    /// never `currentLength == baselineLength`. The prior formula (`delta = currentLength -
    /// baselineLength`) treated the ledger's own length as if it were drift, so even a completely
    /// untouched insertion reported `delta == ledgerLength` and requested `ledgerLength +
    /// ledgerLength` characters — for an insertion at the END of an otherwise-untouched field
    /// this silently absorbed whatever the user typed right after it and reported it as an edit
    /// to the dictated text (concretely: baseline "Hello dog", inserted "cat" before "dog" →
    /// field becomes "Hello catdog"; the old formula read six characters — "catdog" — and treated
    /// it as a one-token correction `cat -> catdog`, which then REPLACED the real "cat" and left
    /// "Hello catdogdog" behind).
    ///
    /// `delta` now measures drift against `baselineLength + ledgerLength` — the field's expected
    /// length if nothing outside the tracked range changed — so 0 means exactly that: an
    /// untouched insertion, or an edit within the tracked range that didn't change its length.
    /// `delta` is allowed up to `editWatcherDeltaBound` in either direction (a genuine correction
    /// shifts the total length by a handful of characters; continued unrelated typing blows past
    /// the bound almost immediately and fails closed rather than reading arbitrarily far past the
    /// range the app itself inserted), and the read is bounded to exactly `ledgerLength + delta` —
    /// the true length of whatever now occupies the tracked range, growing OR shrinking with it,
    /// never clamped back up to `ledgerLength` on a shrink (unlike the pre-fix formula's `max(0,
    /// delta)`, which existed only to compensate for the wrong baseline and would otherwise mask
    /// a genuine same-range shrink, e.g. a misheard four-letter word corrected down to one).
    nonisolated static func boundedEditedLength(
        currentLength: Int, baselineLength: Int, ledgerLength: Int
    ) -> Int? {
        let delta = currentLength - (baselineLength + ledgerLength)
        guard abs(delta) <= editWatcherDeltaBound else { return nil }
        let editedLength = ledgerLength + delta
        guard editedLength >= 0 else { return nil }
        return editedLength
    }

    private static func numberOfCharacters(_ element: AXUIElement) -> Int? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
              let number = ref as? NSNumber else { return nil }
        return number.intValue
    }

    private static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &ref
        ) == .success, let text = ref as? String else { return nil }
        return text
    }

    /// One fresh caret+baseline snapshot, taken immediately before a BATCH (non-streaming) paste
    /// — the Correction Loop counterpart of what `LiveInsertionSession.receivePartial` captures
    /// on its first post, reusing the exact same two primitives (`streamingWriteCaret`,
    /// `streamingBaselineValue`) rather than a parallel implementation. `nil` (AX untrusted,
    /// drifted, secure, or an active selection) means Correction Loop simply won't offer a
    /// correction for this insertion — it never blocks or alters the paste itself, which runs
    /// through its own, separate (non-strict) drift check in `insert(_:target:strict:)`. See
    /// `RecentInsertion`.
    @MainActor
    static func captureCorrectionAnchor(target: InsertionTarget) -> (anchor: Int, baseline: String)? {
        guard let anchor = streamingWriteCaret(target: target, expectedCaret: nil) else { return nil }
        guard let baseline = streamingBaselineValue(target: target) else { return nil }
        return (anchor, baseline)
    }

    /// The BATCH (non-streaming) paste path's `insert:` closure, shared by every call site
    /// (`processDictation`'s two default parameters, `runPipeline`'s production closure) so none
    /// of them can independently forget to either note or clear the pending Correction Loop
    /// snapshot (`RecentInsertionStore`'s doc comment explains why a stale pending must always be
    /// explicitly cleared, never just left for the next dictation to overwrite). Captures the
    /// pre-paste caret+baseline BEFORE posting (position after paste is unknowable — it's
    /// whatever the target app does with ⌘V) and only keeps it if the paste actually posted.
    @MainActor
    static func insertTrackingCorrection(_ text: String, target: InsertionTarget?) -> Bool {
        let snapshot = target.flatMap { captureCorrectionAnchor(target: $0) }
        let posted = insert(text, target: target).posted
        if posted, let target, let snapshot {
            RecentInsertionStore.shared.notePending(.init(target: target, baselineValue: snapshot.baseline, anchor: snapshot.anchor, text: text))
        } else {
            RecentInsertionStore.shared.clearPending()
        }
        return posted
    }

    /// What a two-phase insertion (`AppCoordinator.EarlyInsertionHandler`) needs to find the raw
    /// transcript again once post-processing returns: the same (target, baseline, anchor, text)
    /// shape `RecentInsertion` already uses, minus the dictation id — the row doesn't exist yet at
    /// early-insert time. Carried by value through the pipeline rather than re-read from
    /// `RecentInsertionStore`, which a concurrent dictation could have overwritten.
    struct EarlyInsertionReceipt {
        let target: InsertionTarget
        let text: String
        let baselineValue: String
        let anchor: Int
        /// The user's clipboard as it was before phase 1 wrote to it. Both phases suppress
        /// `insert`'s own timed restore (see `restoresPasteboard`) and phase 2 restores this
        /// instead, so a fast post-processing round trip can't leave the raw transcript behind on
        /// the clipboard.
        let savedPasteboard: [[NSPasteboard.PasteboardType: Data]]
    }

    /// Phase 1 of a two-phase insertion: pastes the raw transcript and returns the receipt phase 2
    /// needs. `nil` — the paste didn't post, or the target isn't trackable enough to prove a later
    /// replacement is safe — means the caller must fall back to the ordinary single paste of the
    /// refined text, since without a receipt nothing could ever replace what was typed here.
    @MainActor
    static func insertEarlyTrackingCorrection(_ text: String, target: InsertionTarget) -> EarlyInsertionReceipt? {
        guard let snapshot = captureCorrectionAnchor(target: target) else {
            RecentInsertionStore.shared.clearPending()
            return nil
        }
        let pasteboard = NSPasteboard.general
        let savedPasteboard = pasteboardSnapshot(pasteboard)
        guard insert(text, target: target, restoresPasteboard: false).posted else {
            // Nothing landed in the document, and the caller is about to fall back to the ordinary
            // single paste of the refined text — so put the clipboard back now rather than leaving
            // the raw transcript on it with no phase 2 coming to restore it.
            restore(savedPasteboard, to: pasteboard)
            RecentInsertionStore.shared.clearPending()
            return nil
        }
        RecentInsertionStore.shared.notePending(
            .init(target: target, baselineValue: snapshot.baseline, anchor: snapshot.anchor, text: text)
        )
        return EarlyInsertionReceipt(
            target: target, text: text, baselineValue: snapshot.baseline, anchor: snapshot.anchor,
            savedPasteboard: savedPasteboard
        )
    }

    /// Phase 2: replaces a receipted early insertion with the refined text, through the Correction
    /// Loop's existing select-then-paste path (`CorrectionTargeting.selectRecentInsertion` proves
    /// the document still reads `baseline` with `receipt.text` spliced in at `anchor`, then
    /// live-selects exactly that range) rather than a second replace implementation. `false` means
    /// the document was left holding the raw transcript — drift, a user edit, or a failed paste —
    /// and the refined text is on the pasteboard for a manual paste.
    ///
    /// The pending Correction Loop snapshot is re-noted with the refined text on success:
    /// `RecentInsertion.text` is documented as exactly what is in the document, and after this the
    /// document reads `baseline` + refined at the same anchor.
    @MainActor
    static func replaceEarlyInsertion(_ text: String, receipt: EarlyInsertionReceipt) -> Bool {
        // The id is never read: `selectRecentInsertion` only carries it into the returned
        // `SelectionSnapshot`, which this path discards (no Voice Edit preview/confirm is
        // involved — the replacement is the app's own, already-decided post-processing output).
        let tracked = RecentInsertion(
            dictationID: 0, target: receipt.target, text: receipt.text,
            baselineValue: receipt.baselineValue, anchor: receipt.anchor, insertedAt: Date()
        )
        let pasteboard = NSPasteboard.general
        guard CorrectionTargeting.selectRecentInsertion(tracked) != nil else {
            // The selection failed before anything was written anywhere, so the refined text would
            // otherwise be unreachable outside the library. Put it on the pasteboard here, which is
            // what the `.rawLeftInPlace` HUD promises — `insert`'s own failure path below already
            // leaves it there.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return false
        }
        guard insert(text, target: receipt.target, restoresPasteboard: false).posted else { return false }
        RecentInsertionStore.shared.notePending(
            .init(target: receipt.target, baselineValue: receipt.baselineValue, anchor: receipt.anchor, text: text)
        )
        restoreEarlyInsertionClipboard(receipt)
        return true
    }

    /// Puts back the clipboard phase 1 took over, for every two-phase ending that isn't a
    /// successful `replaceEarlyInsertion` — the refinement coming back byte-identical (so phase 2
    /// is skipped), and any throw between the two phases. Without this, `restoresPasteboard:
    /// false` would leave the raw transcript on the user's clipboard forever.
    ///
    /// Deliberately NOT called from `replaceEarlyInsertion`'s two failure branches: those are the
    /// `.rawLeftInPlace` outcome, whose HUD promises the refined text is on the clipboard.
    ///
    /// Delayed rather than immediate for the same reason `insert`'s own restore is: post-
    /// processing can return while the target app is still reading phase 1's paste.
    @MainActor
    static func restoreEarlyInsertionClipboard(_ receipt: EarlyInsertionReceipt) {
        schedulePasteboardRestore(
            receipt.savedPasteboard, changeCountAfterWrite: NSPasteboard.general.changeCount
        )
    }

    /// One AX attribute read, classified into whether the value was affirmatively present, is
    /// legitimately absent (the attribute doesn't apply to this element — `.noValue`/
    /// `.attributeUnsupported`), or is unreadable for any other reason (Codex finding 1: a
    /// password field that momentarily returns `.cannotComplete` while its selection is still
    /// readable must NOT be treated the same as a plain control that has no subrole at all).
    /// `nonisolated` and generic over the decoded type so it's directly unit-testable without a
    /// live AX session — see `secureCheckResult` below and `StreamingASRSafetyTests`.
    enum AttributeReadOutcome<Value: Equatable>: Equatable {
        case value(Value)
        case absent
        case unreadable
    }

    /// Tri-state result of the secure-field check (Codex finding 1): only `.notSecure` is an
    /// AFFIRMATIVE "safe to stream" answer. `.secure` and `.unreadable` are both treated as unsafe
    /// by every caller — the whole point of this type is to make "doubt" and "confirmed secure"
    /// impossible to conflate at the call site the way the old `Bool` did.
    enum SecureCheckResult: Equatable {
        case notSecure
        case secure
        case unreadable
    }

    /// Pure classification (Codex finding 1), factored out of `isSecureForStreaming` so the
    /// fail-closed-on-doubt behavior is directly unit-testable without a live AX session — same
    /// style as `classifyPreflightFailure`/`shouldSynthesizePaste` above. A subrole/protected-
    /// content read that legitimately doesn't apply to this element (`.absent`) contributes
    /// "not secure via that attribute" (a control with no subrole at all cannot be a secure text
    /// field via subrole); any other unreadable read (`.unreadable` — AX error, type mismatch)
    /// fails the whole check closed to `.unreadable` regardless of what the other attribute says.
    nonisolated static func secureCheckResult(
        subrole: AttributeReadOutcome<String>,
        protectedContent: AttributeReadOutcome<Bool>
    ) -> SecureCheckResult {
        let subroleSecure: Bool
        switch subrole {
        case .value(let value): subroleSecure = value == "AXSecureTextField"
        case .absent: subroleSecure = false
        case .unreadable: return .unreadable
        }
        let protected: Bool
        switch protectedContent {
        case .value(let value): protected = value
        case .absent: protected = false
        case .unreadable: return .unreadable
        }
        return (subroleSecure || protected) ? .secure : .notSecure
    }

    /// Subrole (not role — see the note above) + protected content, read from one element, then
    /// classified tri-state (Codex finding 1: DEFERRED-FINDINGS.md's F4 entry claims
    /// `streamingStartGate`/`streamingSafeElement` "fail closed when unreadable" — this is what
    /// makes that claim actually true, rather than the previous `Bool` collapse that silently
    /// turned every AX error into "not secure").
    private static func isSecureForStreaming(_ element: AXUIElement) -> Bool {
        var subroleRef: AnyObject?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subroleOutcome: AttributeReadOutcome<String>
        switch subroleError {
        case .success:
            if let subrole = subroleRef as? String {
                subroleOutcome = .value(subrole)
            } else {
                subroleOutcome = .unreadable
            }
        case .noValue, .attributeUnsupported:
            subroleOutcome = .absent
        default:
            subroleOutcome = .unreadable
        }

        var protectedRef: AnyObject?
        let protectedError = AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protectedRef)
        let protectedOutcome: AttributeReadOutcome<Bool>
        switch protectedError {
        case .success:
            if let boolValue = protectedRef as? Bool {
                protectedOutcome = .value(boolValue)
            } else if let number = protectedRef as? NSNumber {
                protectedOutcome = .value(number.boolValue)
            } else {
                protectedOutcome = .unreadable
            }
        case .noValue, .attributeUnsupported:
            protectedOutcome = .absent
        default:
            protectedOutcome = .unreadable
        }

        switch secureCheckResult(subrole: subroleOutcome, protectedContent: protectedOutcome) {
        case .notSecure: return false
        case .secure, .unreadable: return true
        }
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(rangeRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Compares the snapshotted focused element/window against what's focused right now.
    /// Prefers the element comparison (finer-grained); falls back to the window only when no
    /// element was snapshotted. Both nil at snapshot time (AX-opaque app) → `.unavailable`.
    private static func compareElements(snapshot: InsertionTarget?, currentElement: AXUIElement?, currentWindow: AXUIElement?) -> ElementComparison {
        guard let snapshot else { return .unavailable }
        if let snapshotElement = snapshot.focusedElement {
            guard let currentElement else { return .mismatch }
            // AXUIElement is CFEqual-comparable for identity — see AXUIElement.h.
            return CFEqual(snapshotElement, currentElement) ? .match : .mismatch
        }
        if let snapshotWindow = snapshot.window {
            guard let currentWindow else { return .mismatch }
            return CFEqual(snapshotWindow, currentWindow) ? .match : .mismatch
        }
        return .unavailable
    }

    /// `kAXDocumentAttribute`, read from whichever of `window`/`element` exposes it (window
    /// preferred — document identity is generally window-level). Captured on every snapshot
    /// (`snapshotTarget`) for `InsertionTarget.document` — see that property's doc comment for
    /// why it's consulted only by `SelectionAccess`'s correction-fallback revalidation, never by
    /// `compareElements`/`streamingSafeElement`/`insert`. `nil` when neither exposes it (most
    /// apps).
    private static func documentDiscriminator(element: AXUIElement?, window: AXUIElement?) -> String? {
        if let window, let document = stringAttribute(window, kAXDocumentAttribute as CFString) { return document }
        if let element, let document = stringAttribute(element, kAXDocumentAttribute as CFString) { return document }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Returns the given app's currently focused UI element via AX, or nil if there is none or
    /// the AX query fails (e.g. an AX-opaque app). Shared by the identity snapshot/comparison
    /// above and `isEditableFocusedElement` below, so both look at the exact same element rather
    /// than issuing two separate (and potentially inconsistent) AX queries.
    private static func focusedElement(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard result == .success, let focusedRef else { return nil }
        return (focusedRef as! AXUIElement) // swiftlint:disable:this force_cast
    }

    /// Returns the given element's containing AXWindow, or nil if unobtainable. "Cheap" — a
    /// single AX attribute read, no extra traversal.
    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        var windowRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef)
        guard result == .success, let windowRef else { return nil }
        return (windowRef as! AXUIElement) // swiftlint:disable:this force_cast
    }

    /// Checks whether `element` (the frontmost app's focused UI element, already fetched by the
    /// caller) is a plausible paste target: either AX reports its value as settable, or its role
    /// is a known text-bearing role. If AX can't answer conclusively (no focused element, role
    /// unknown, settability unknown), this defaults to `true` — never blocking a paste on
    /// missing AX data, since losing dictated text is worse than an occasional paste into a
    /// non-text control. Only skips when AX affirmatively says the focused element is a known,
    /// non-text-settable control, or there's no focused element at all.
    // ponytail: permissive AX editability heuristic + upgrade path: per-app allowlist.
    private static func isEditableFocusedElement(_ element: AXUIElement?) -> Bool {
        guard let element else {
            // No focused element at all — nothing to paste into.
            return false
        }

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settableResult == .success, settable.boolValue {
            return true
        }

        var roleRef: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea"]
        if roleResult == .success, let role = roleRef as? String {
            if textRoles.contains(role) { return true }
            if settableResult == .success {
                // Role known and value affirmatively not settable — a non-text control.
                return false
            }
        }

        // AX query errored or gave inconclusive info — permissive default.
        return true
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let newItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(newItems)
    }

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        let location = CGEventTapLocation.cghidEventTap
        keyDown.post(tap: location)
        keyUp.post(tap: location)
        return true
    }
}
