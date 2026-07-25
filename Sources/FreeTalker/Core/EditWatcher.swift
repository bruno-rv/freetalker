import ApplicationServices
import Foundation

/// Correction Loop signal C (BRAINSTORM_CORRECTION_LOOP.md), OFF by default
/// (`AppSettings.correctionLoopEditWatcherEnabled`): for a bounded window after an insertion,
/// polls the SAME AX element `RecentInsertionStore` already verified and offers to remember a
/// single anchored-word edit — never applies one automatically. Reuses `Insertion.
/// streamingSafeElement` (fresh identity/security check before every read) and
/// `Insertion.extractEditedReplacement` (confined strictly to the app's own inserted range) plus
/// `CorrectionRecorder.candidate` (the same anchored-substitution diff every signal uses) — no
/// parallel detection logic. Any AX read failure (an app that exposes text badly — Electron, most
/// web views) just stops watching for this insertion; it never surfaces as broken.
@MainActor
final class EditWatcher {
    static let shared = EditWatcher()
    private init() {}

    static let pollInterval: TimeInterval = 2
    /// Deliberately shorter than `RecentInsertionStore.window` — signal C is the riskiest of the
    /// three (the only one reading text the user didn't explicitly hand over), so it gets the
    /// tightest bound.
    static let window: TimeInterval = 90

    private var task: Task<Void, Never>?

    /// Called once per successful insertion (see `AppCoordinator`'s wiring, right where
    /// `RecentInsertionStore` gets its dictation id attached). A no-op unless the setting is on.
    /// Cancels any watcher still running for a PRIOR insertion first — only ever one insertion is
    /// watched at a time, matching "the most recent dictation" everywhere else in this feature.
    func beginWatching(dictationID: Int64) {
        task?.cancel()
        task = nil
        guard AppSettings.shared.correctionLoopEditWatcherEnabled else { return }
        let deadline = Date().addingTimeInterval(Self.window)
        task = Task { [weak self] in
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.checkOnce(dictationID: dictationID)
            }
        }
    }

    func stopWatching() {
        task?.cancel()
        task = nil
    }

    private func checkOnce(dictationID: Int64) {
        guard let recent = RecentInsertionStore.shared.recent(), recent.dictationID == dictationID else {
            stopWatching()
            return
        }
        guard let element = Insertion.streamingSafeElement(target: recent.target) else { return }
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let current = valueRef as? String else { return }
        guard let replacement = Insertion.extractEditedReplacement(
            current: Array(current.utf16), baseline: Array(recent.baselineValue.utf16),
            ledgerLength: recent.text.utf16.count, anchor: recent.anchor
        ) else { return }
        let observed = String(utf16CodeUnits: replacement, count: replacement.count)
        guard observed != recent.text else { return }
        guard CorrectionRecorder.candidate(wrongText: recent.text, rightText: observed) != nil else { return }
        stopWatching()
        CorrectionPanelController.shared.openForObservedEdit(dictationID: dictationID, after: observed)
    }
}
