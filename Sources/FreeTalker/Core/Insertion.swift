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
}

/// Inserts the Refined Output at the cursor of the frontmost app via the pasteboard +
/// synthetic ⌘V, restoring the previous pasteboard contents afterward. See PLAN.md step 6.
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
        return InsertionTarget(bundleID: app.bundleIdentifier, pid: app.processIdentifier, focusedElement: element, window: window)
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
    /// re-process) preserves the pre-fix behavior of always pasting. See Codex finding: paste-
    /// target drift / same-app target drift.
    @discardableResult
    static func insert(_ text: String, target: InsertionTarget? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        } ?? []

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

        guard shouldSynthesizePaste(
            hasTarget: target != nil,
            snapshotBundleID: target?.bundleID,
            currentBundleID: currentBundleID,
            pidMatch: pidMatch,
            elementComparison: elementComparison
        ) else {
            // Identity drifted since the snapshot — leave the text on the pasteboard for a
            // manual paste rather than pasting into whatever now has focus.
            return false
        }

        guard isEditableFocusedElement(currentElement) else {
            // No focused element, or AX affirmatively says it's not a text control — leave our
            // text on the pasteboard and don't touch it further. See Round 2 Codex finding 1.
            return false
        }

        let posted = postCommandV()

        if posted {
            // Timed restore: deliberate, logged decision — a residual race remains if the target
            // app is slow to read the pasteboard, but a completion signal isn't available via
            // public API. 1.0s (up from 0.3s) narrows the window; changeCount guard still skips
            // the restore if anything else wrote to the pasteboard first. See Round 1 Codex
            // finding 5 / Round 2 Codex finding 2.
            // ponytail: timed restore, residual race accepted for personal use + upgrade path:
            // skip restore option in Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard pasteboard.changeCount == changeCountAfterWrite else { return }
                restore(savedItems, to: pasteboard)
            }
        }
        return posted
    }

    /// Pure paste-target-drift decision, split out so SelfCheck can drive it with synthetic
    /// identity data.
    ///
    /// `hasTarget` is the *only* switch for the permissive "nothing to compare against" path:
    /// `false` means no snapshot was taken at all (e.g. `AppCoordinator.reprocess`, which has no
    /// frontmost-app snapshot for a historical re-process) → `true`, preserving the pre-fix
    /// behavior of always pasting; `pidMatch`/`elementComparison`/bundle ids are irrelevant here
    /// and never evaluated. This must NOT be conflated with "a snapshot was taken but its bundle
    /// id happened to be nil" (`app.bundleIdentifier == nil`, which some apps report) — that case
    /// has `hasTarget == true` and still goes through the full pid + element gate below. See
    /// Round 3 Codex finding: nil-bundleID snapshot bypassing the drift gate.
    ///
    /// When `hasTarget` is `true`, bundle id is checked first:
    /// - Both non-nil → must be equal, else `false` (the user switched apps).
    /// - `snapshotBundleID == nil`, `currentBundleID` anything → bundle id carries no information
    ///   (it was unknown at snapshot time), so this doesn't contradict identity on its own; the
    ///   decision falls through entirely to `pidMatch`/`elementComparison`.
    /// - `snapshotBundleID != nil`, `currentBundleID == nil` → `false`. We *did* know the
    ///   intended target and now can't identify what's frontmost, which is exactly the "can't
    ///   confirm it's safe" situation this check exists to catch — stranding the text on the
    ///   pasteboard (recoverable via manual paste) beats pasting into an unidentifiable target.
    ///
    /// Once bundle id doesn't contradict, `pidMatch` (default `true`, i.e. "no pid info to
    /// contradict") must also hold — bundle id alone doesn't distinguish two windows of the same
    /// app if macOS ever reuses/aliases identifiers oddly, and a pid mismatch is an unambiguous
    /// signal something changed. `elementComparison` then refines *within* the same process:
    /// - `.match` / `.unavailable` → paste allowed (`.unavailable` covers both "no snapshot" and
    ///   "snapshot app was AX-opaque, neither element nor window were obtainable" — falls back to
    ///   bundle+pid identity, same as the pre-fix behavior, plus the existing editability probe
    ///   called separately after this gate).
    ///   // ponytail: bundle+pid-only fallback for AX-opaque apps + upgrade path: none currently
    ///   available — AX element/window identity is the only public surface finer than bundle id,
    ///   so an app that denies AX queries entirely has no stronger signal to fall back to.
    /// - `.mismatch` → the focused element (or window) changed within the same app/process since
    ///   the snapshot — e.g. a different Slack channel or Mail draft — so the paste is skipped.
    nonisolated static func shouldSynthesizePaste(
        hasTarget: Bool,
        snapshotBundleID: String?,
        currentBundleID: String?,
        pidMatch: Bool = true,
        elementComparison: ElementComparison = .unavailable
    ) -> Bool {
        guard hasTarget else { return true }
        if let snapshotBundleID {
            guard let currentBundleID, snapshotBundleID == currentBundleID else { return false }
        }
        guard pidMatch else { return false }
        switch elementComparison {
        case .mismatch: return false
        case .match, .unavailable: return true
        }
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
