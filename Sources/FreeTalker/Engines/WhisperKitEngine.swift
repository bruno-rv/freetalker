import Foundation
import WhisperKit
import os

/// Serializes async operations so at most one runs at a time. Shared between the live preview
/// loop's periodic partial transcriptions and the final full-buffer transcription so WhisperKit
/// never runs two `transcribe`/`detectLangauge` calls concurrently — a bare `actor` isn't
/// enough here, since reentrancy at an `await` inside an actor method lets a second caller's
/// operation start before the first finishes; this keeps an explicit FIFO wait queue instead.
/// See PLAN 3 "Concurrency rules".
///
/// Cancellation-aware (Codex finding, live-preview streaming PLAN): a waiter's `Task` can be
/// cancelled while it's still queued — the live preview loop's `keyUp` cancellation is the
/// concrete case, see `AppCoordinator.stopLivePreview`. Without this, a cancelled preview tick
/// queued behind another `run` (preload, or the final transcription itself) would still run a
/// full WhisperKit pass before the *next* caller (the real final transcription) ever got the
/// gate — user-visible delay at the exact moment latency matters most. Waiters are tracked by
/// `UUID` (not a bare array of continuations) so a cancelled one can be located and removed from
/// the queue individually rather than only ever being resumable in FIFO order.
actor SerialGate {
    private var isBusy = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waiterOrder: [UUID] = []

    /// Runs `operation` once the gate is free. Cancellation-aware end to end: a caller whose
    /// enclosing `Task` is cancelled while still queued behind another `run` never executes
    /// `operation` at all — `acquire()` throws `CancellationError` instead of ever handing it
    /// the gate. A caller cancelled *after* it already has the gate (the small window between
    /// `acquire()` returning and `operation` starting) is also caught, by the
    /// `Task.checkCancellation()` below, before `operation` runs.
    ///
    /// This gate itself has no way to interrupt `operation` once it has started — it's a
    /// generic mutual-exclusion primitive, not WhisperKit-aware. Closing that gap for an
    /// already-*running* preview decode (Round 2 Codex finding: final-path priority — a
    /// cancelled preview tick must not make the final transcription wait behind a full decode
    /// it's mid-way through) is handled one layer up, in `WhisperKitEngine.transcribe`/
    /// `performTranscribe`, via WhisperKit's own per-token `TranscriptionCallback`, not here.
    ///
    /// No separate "final transcription jumps the queue" priority scheme: cancellation-awareness
    /// alone already satisfies the requirement here, because the only thing that can ever be
    /// queued in front of a final transcription is a live preview tick, and that tick's owning
    /// `Task` is cancelled at the exact moment `keyUp` fires (`AppCoordinator.stopLivePreview`,
    /// called before the final pipeline starts) — it drops out of the queue immediately rather
    /// than ever reaching the front of it. Adding explicit priority would only matter if some
    /// other *uncancelled* caller could be queued ahead of a final transcription, which isn't a
    /// case that exists today (the only other caller is `preload()`, which runs once at launch).
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        if !isBusy {
            isBusy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters[id] = continuation
                waiterOrder.append(id)
            }
        } onCancel: {
            // `onCancel` is not actor-isolated and can fire concurrently with — even before —
            // the continuation's registration above, so it must never touch actor state
            // directly. Spawning a `Task` here is what makes this race-free rather than
            // best-effort: the registration closure above is synchronous, non-suspending
            // actor-isolated code, so it always runs to completion (setting `waiters[id]`)
            // before this spawned `Task` can get a turn on the actor's executor. `cancelWaiter`
            // therefore never observes an unregistered continuation.
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while let id = waiterOrder.first {
            waiterOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
            // This id was already cancelled out from under it (removed from `waiters` by
            // `cancelWaiter` but not yet from `waiterOrder`'s front — shouldn't happen since
            // both are mutated together, but keep looking rather than risk deadlocking on a
            // dangling id instead of ever clearing `isBusy`).
        }
        isBusy = false
    }
}

/// On-device transcription via WhisperKit's `large-v3-turbo` model. The model is downloaded
/// and cached by WhisperKit/Hub on first use (~1 GB); see ADR-0001.
///
/// The class itself is nonisolated (`transcribe` does CPU-heavy work that must not tie up the
/// main actor); only `statusText` is main-actor-isolated since it feeds SwiftUI directly.
/// `@unchecked Sendable` is safe here because the only mutable state that matters for Sendable
/// purposes, `whisperKit`, is fully gate-confined: it is written only inside `loadedKit()` and
/// read only inside `loadedKit()`/`performTranscribe()`, and every call site that can reach
/// those two methods (`transcribe`, `preload`) does so exclusively through `gate.run`, which
/// serializes them so at most one is ever "inside" at a time. `whisperKit` itself carries no
/// `nonisolated(unsafe)` annotation and is never touched from outside that gated path — in
/// particular, `isLoaded` (below) does not read it. Load state that genuinely does need a cheap
/// synchronous cross-context read is published separately via `loadedFlag`, a lock-guarded
/// `Bool` that's actually safe to read/write concurrently (unlike a bare strong-ref read/write,
/// which is not atomic under Swift concurrency — see prior Codex finding this replaces).
final class WhisperKitEngine: ObservableObject, TranscriptionEngine, @unchecked Sendable {
    let name = "WhisperKit (large-v3-turbo)"
    @MainActor @Published private(set) var statusText: String = "Not loaded"

    // Exact HF repo folder name for the large-v3-turbo CoreML export — avoids ambiguous
    // glob matches against sibling variants (distil/turbo/dated) in the model repo.
    private static let modelVariant = "large-v3_turbo_954MB"

    private var whisperKit: WhisperKit?
    private let gate = SerialGate()

    /// Set to `true` inside `loadedKit()`, exactly once, right after the gated load completes —
    /// never reset to `false` (no unload path exists). `OSAllocatedUnfairLock` (macOS 13+;
    /// deployment target is macOS 26, see Package.swift) gives a genuinely thread-safe
    /// synchronous read/write, unlike the `nonisolated(unsafe)` strong-ref read this replaces:
    /// a class reference read racing a gated write is undefined behavior under Swift
    /// concurrency, not just imprecise — `Bool` reads/writes under a lock are well-defined.
    private let loadedFlag = OSAllocatedUnfairLock(initialState: false)

    /// Whether the model has already been loaded (preloaded at launch, or lazily by an earlier
    /// call). Read by the live preview availability check — see PLAN 3 "Settings": when Cloud
    /// STT is the active engine, preview must never trigger a fresh multi-hundred-MB local model
    /// load just to satisfy a tick; it only runs if WhisperKit already happens to be loaded.
    /// Reads `loadedFlag`, not `whisperKit` — this stays a cheap synchronous property (its call
    /// sites are a SwiftUI view body and a non-async AppCoordinator method, neither of which can
    /// await a gated read without much larger ripple) while keeping `whisperKit` itself fully
    /// gate-confined.
    var isLoaded: Bool { loadedFlag.withLock { $0 } }

    /// Warms up the model outside the hot path (e.g. at app launch) so the first real
    /// dictation doesn't pay the load/download cost. Errors are swallowed into `statusText`
    /// (already visible in the menu bar) rather than thrown — nothing here is user-initiated.
    func preload() async {
        do {
            // Routed through `gate` too — otherwise a live preview tick firing mid-launch-load
            // (PLAN 3: preview starts as soon as a recording begins, independent of whether
            // preload has finished) could call `loadedKit()` a second time concurrently with
            // this one, racing two `WhisperKit.download`/load calls against the same cache dir.
            // See PLAN 3 "Concurrency rules".
            // Discards inside the closure (not `_ = gate.run { ... }`) — `WhisperKit` itself
            // isn't `Sendable`, so the gate's `T: Sendable` result type must be inferred as
            // `Void`, not the loaded instance.
            try await gate.run { _ = try await self.loadedKit() }
        } catch {
            await setStatus("Preload failed: \(error.localizedDescription)")
        }
    }

    // ponytail: supported languages are hardcoded to {en, pt} per PLAN.md/CONTEXT.md (the app
    // only targets English and Brazilian Portuguese). Upgrade path: source this set from a
    // Settings-configurable language list once more languages are supported.
    private static let supportedLanguages = ["en", "pt"]

    /// Public entry point — routes through `gate` so this never overlaps another `transcribe`
    /// call (partial preview or final), then does the actual work in `performTranscribe`. See
    /// PLAN 3 "Concurrency rules".
    ///
    /// `allowEarlyCancel` (preview-only, default `false`): when `true`, an in-flight decode
    /// *may* abort as soon as the calling `Task` is cancelled — even after it has already
    /// acquired `gate` and started decoding — via a per-token early-stop `TranscriptionCallback`
    /// (fires once per generated token; see `performTranscribe`). This is opportunistic, not a
    /// bound: WhisperKit 0.18.0's pre-decode stages (logmel, encoder CoreML calls) aren't
    /// interruptible, and the callback itself fires from a low-priority detached `Task`, so a
    /// cancellation can be delayed arbitrarily (Codex round-3 finding). The actual hard bound on
    /// a preview tick's worst-case runtime comes from the caller feeding a constant-size window
    /// instead of the whole growing recording (`AudioCapture.snapshotSuffix`) plus this flag
    /// also selecting reduced `DecodingOptions` below (temperature-fallback retries disabled) —
    /// together those cap one tick's cost independent of cancellation ever landing at all. When
    /// it does land in time, `keyUp`'s `livePreviewTask.cancel()` (`AppCoordinator.stopLivePreview`)
    /// still shaves off whatever's left of that bounded pass. See Round 2 Codex finding:
    /// final-path priority.
    ///
    /// Never pass `true` for the final transcription — the plan invariant is that the final path
    /// always runs to completion, uninterrupted. `TranscriptionEngine`'s protocol requirement
    /// (`transcribe(samples:forcedLanguage:)`, no `allowEarlyCancel`) is satisfied by the overload
    /// just below, which hardcodes `false` — so every call reached through the protocol (i.e. the final
    /// pipeline, which only ever holds an `any TranscriptionEngine`) is final-path behavior by
    /// construction, and can never behave differently than before this fix. Swift's protocol
    /// witness matching doesn't accept a defaulted extra parameter as satisfying a stricter
    /// requirement, which is why this is two overloads rather than one method with a default.
    func transcribe(samples: [Float], forcedLanguage: String?, allowEarlyCancel: Bool) async throws -> TranscriptionOutput {
        guard allowEarlyCancel else {
            return try await gate.run { [self] in try await performTranscribe(samples: samples, forcedLanguage: forcedLanguage, cancelFlag: nil) }
        }
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await gate.run { [self] in try await performTranscribe(samples: samples, forcedLanguage: forcedLanguage, cancelFlag: cancelFlag) }
        } onCancel: {
            cancelFlag.withLock { $0 = true }
        }
    }

    /// `TranscriptionEngine` conformance — the final-transcription entry point. Always
    /// `allowEarlyCancel: false`; see the overload above.
    func transcribe(samples: [Float], forcedLanguage: String?) async throws -> TranscriptionOutput {
        try await transcribe(samples: samples, forcedLanguage: forcedLanguage, allowEarlyCancel: false)
    }

    /// Pure decision for the preview-only early-stop `TranscriptionCallback` WhisperKit invokes
    /// once per decoded token (`TextDecoder.swift`'s decode loop). Returning `false` is
    /// WhisperKit's documented "stop decoding now" signal; `true`/`nil` continue. See
    /// `performTranscribe`.
    nonisolated static func earlyStopDecision(cancelled: Bool) -> Bool {
        !cancelled
    }

    /// Pure decision: whether a transcription result must be discarded because it came from an
    /// early-stopped (cancelled) preview decode rather than surfaced as if it were complete.
    /// WhisperKit does *not* throw when its callback early-stops the loop — it returns a normal
    /// result built from whatever partial tokens had already been generated (see
    /// `TextDecoder.swift`: the loop just `break`s) — so this cancellation flag is the only
    /// signal that distinguishes "real, complete result" from "leftover partial tokens from an
    /// aborted pass". See Round 2 Codex finding.
    nonisolated static func shouldDiscardPreviewResult(cancelled: Bool) -> Bool {
        cancelled
    }

    /// Throws once `cancelFlag` has been set (see `transcribe(allowEarlyCancel:)`). Checked at
    /// each pipeline-stage boundary named in the Round 2 Codex finding — after acquiring the
    /// gate/loading the model, after language detection, and immediately before decode starts —
    /// so a preview tick cancelled while waiting on one of the non-decode stages never even
    /// reaches WhisperKit's decode loop. A no-op when `cancelFlag` is `nil` (the
    /// final-transcription path).
    private func checkPreviewCancellation(_ cancelFlag: OSAllocatedUnfairLock<Bool>?) throws {
        if let cancelFlag, cancelFlag.withLock({ $0 }) {
            throw CancellationError()
        }
    }

    private func performTranscribe(samples: [Float], forcedLanguage: String?, cancelFlag: OSAllocatedUnfairLock<Bool>?) async throws -> TranscriptionOutput {
        let kit = try await loadedKit()
        try checkPreviewCancellation(cancelFlag)

        do {
            let language: String
            if let forcedLanguage {
                // Language Pin (CONTEXT.md): the caller already resolved this to "en"/"pt" (one-
                // shot > app rule > pin) — skip auto-detect entirely and decode directly in that
                // language. See PLAN.md step 5.
                language = forcedLanguage
            } else {
                await setStatus("Detecting language…")
                // Whisper's unconstrained auto-detect spans ~99 languages and misfires badly on
                // short utterances (e.g. English "Hello, 1 2 3 4 5 6" hallucinated as Portuguese).
                // Restrict the winner to the two languages this app actually supports, then pin
                // the real decode to it instead of letting WhisperKit detect+decode freely.
                let (_, langProbs) = try await kit.detectLangauge(audioArray: samples)
                try checkPreviewCancellation(cancelFlag)
                language = Self.supportedLanguages.max { langProbs[$0, default: -.infinity] < langProbs[$1, default: -.infinity] } ?? "en"
            }

            await setStatus("Transcribing…")
            var options = DecodingOptions()
            options.language = language
            options.usePrefillPrompt = true
            options.detectLanguage = false
            // Preview path only (`cancelFlag != nil` ⟺ `allowEarlyCancel: true`, see
            // `transcribe(allowEarlyCancel:)`): reduced decode effort is the other half of the
            // constant-cost preview bound alongside `AudioCapture.snapshotSuffix` (Codex round-3
            // finding — pre-decode WhisperKit stages aren't interruptible, so the tick's own cost
            // must be bounded independently of cancellation, not just made faster to cancel).
            // Temperature-fallback retries re-run the whole decode up to
            // `temperatureFallbackCount` additional times when WhisperKit's own quality heuristics
            // (compression ratio / log-prob thresholds) reject a pass — worth paying for the
            // final transcript, not for a preview tick that's superseded within
            // `livePreviewTickInterval` seconds anyway. `wordTimestamps` is already `false` by
            // default (never set true anywhere in this app), so there's nothing to additionally
            // disable there. The final path (`cancelFlag == nil`) is untouched — same defaults as
            // before this fix.
            if cancelFlag != nil {
                options.temperatureFallbackCount = 0
            }

            // Bias decoding toward user-registered vocabulary (proper nouns/jargon) via
            // WhisperKit's `promptTokens`, following the same encode pattern as WhisperKit's own
            // CLI/server prompt handling (leading space, special tokens filtered out).
            let vocabulary = await AppSettings.shared.vocabulary
            if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
                let promptText = " " + vocabulary.joined(separator: ", ")
                options.promptTokens = tokenizer.encode(text: promptText)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }

            try checkPreviewCancellation(cancelFlag)

            // Preview-only: installs a per-token early-stop callback so an in-flight decode can
            // actually be aborted (see `transcribe(allowEarlyCancel:)`). `cancelFlag` is `nil` on
            // the final path, so `callback` stays `nil` there and `kit.transcribe` behaves
            // exactly as it did before this fix. The closure itself must stay cheap/synchronous
            // — WhisperKit calls it from a background `Task.detached` once per generated token
            // and warns it "should be lightweight and return as quickly as possible" — a lock
            // read is the right size for that.
            let callback: TranscriptionCallback = cancelFlag.map { flag in
                { _ in Self.earlyStopDecision(cancelled: flag.withLock { $0 }) }
            }

            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: callback)

            // See `shouldDiscardPreviewResult` — an early-stopped decode returns normally with
            // partial text rather than throwing, so cancellation has to be checked explicitly
            // here rather than inferred from a caught error.
            if let cancelFlag, Self.shouldDiscardPreviewResult(cancelled: cancelFlag.withLock({ $0 })) {
                await setStatus("Ready")
                throw CancellationError()
            }

            await setStatus("Ready")
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            // When forced, the recorded language is always the forced code — never whatever
            // WhisperKit's decode result happens to report — mirroring CloudSTTEngine's contract.
            // See PLAN.md step 5.
            return TranscriptionOutput(text: text, language: forcedLanguage ?? results.first?.language ?? language)
        } catch {
            await setStatus("Ready")
            throw error
        }
    }

    // ponytail: no single-flight guard for concurrent loads — AppCoordinator already
    // serializes calls via its isRecording/isProcessing state, so re-entry can't happen.
    private func loadedKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        let kit = try await loadModel()
        whisperKit = kit
        loadedFlag.withLock { $0 = true }
        return kit
    }

    private func loadModel() async throws -> WhisperKit {
        await setStatus("Checking for model…")
        let folder = try await WhisperKit.download(variant: Self.modelVariant) { [weak self] progress in
            let percent = Int(progress.fractionCompleted * 100)
            Task { @MainActor in self?.statusText = "Downloading model… \(percent)%" }
        }
        await setStatus("Loading model…")
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .none, load: true, download: false)
        let kit = try await WhisperKit(config)
        await setStatus("Ready")
        return kit
    }

    @MainActor
    private func setStatus(_ text: String) {
        statusText = text
    }
}
