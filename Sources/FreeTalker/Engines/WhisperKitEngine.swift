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
/// purposes is held by `GuardedKitState`: kit identity and loaded variant are read and swapped
/// under one lock. The transcription gate still serializes WhisperKit inference, while reloads
/// construct a candidate outside that gate and perform only the final atomic state swap.
final class GuardedKitState<Kit>: @unchecked Sendable {
    private final class KitBox: @unchecked Sendable {
        let value: Kit
        init(_ value: Kit) { self.value = value }
    }
    struct Snapshot: @unchecked Sendable {
        let kit: Kit?
        let variant: String?
    }

    private struct State: @unchecked Sendable {
        var kit: KitBox?
        var variant: String?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isLoaded: Bool { lock.withLock { $0.kit != nil } }
    func snapshot() -> Snapshot { lock.withLock { Snapshot(kit: $0.kit?.value, variant: $0.variant) } }
    func installIfEmpty(kit: Kit, variant: String) {
        let box = KitBox(kit)
        lock.withLock { state in
            guard state.kit == nil else { return }
            state = State(kit: box, variant: variant)
        }
    }
    func swap(kit: Kit, variant: String) {
        let box = KitBox(kit)
        lock.withLock { $0 = State(kit: box, variant: variant) }
    }
}

final class ModelReloadController<Kit>: @unchecked Sendable {
    private final class ResultBox: @unchecked Sendable { var kit: Kit? }
    typealias Loader = @Sendable (String) async throws -> Kit
    typealias EventSink = @Sendable (SpeechModelEngineEvent, String) async -> Void
    typealias SettingReader = @Sendable () async -> String
    typealias SettingReverter = @Sendable (String, String) async -> Void
    typealias InstallSink = @Sendable (String) async -> Void

    let state = GuardedKitState<Kit>()
    private let reloadGate = SerialGate()

    func loadIfNeeded(
        requested: String,
        loader: @escaping Loader,
        event: @escaping EventSink,
        didInstall: @escaping InstallSink
    ) async throws -> Kit {
        if let kit = state.snapshot().kit { return kit }
        let result = ResultBox()
        try await reloadGate.run {
            if let existing = self.state.snapshot().kit {
                result.kit = existing
                return
            }
            await event(.busy(reloadTarget: requested), requested)
            do {
                let kit = try await loader(requested)
                self.state.installIfEmpty(kit: kit, variant: requested)
                let installed = self.state.snapshot()
                await event(.active, installed.variant ?? requested)
                await didInstall(installed.variant ?? requested)
                result.kit = installed.kit ?? kit
            } catch {
                await event(.failed(hint: error.localizedDescription), requested)
                throw error
            }
        }
        return result.kit!
    }

    func reload(
        to requested: String,
        currentSetting: @escaping SettingReader,
        revertSetting: @escaping SettingReverter,
        loader: @escaping Loader,
        event: @escaping EventSink,
        didInstall: @escaping InstallSink
    ) async {
        try? await reloadGate.run {
            var target: String? = requested
            while let requestedVariant = target {
                let oldVariant = self.state.snapshot().variant
                guard WhisperKitEngine.shouldReload(loadedVariant: oldVariant, requestedVariant: requestedVariant) else { return }
                await event(.busy(reloadTarget: requestedVariant), requestedVariant)
                do {
                    let candidate = try await loader(requestedVariant)
                    self.state.swap(kit: candidate, variant: requestedVariant)
                    await event(.active, requestedVariant)
                    await didInstall(requestedVariant)
                } catch {
                    await event(.failed(hint: error.localizedDescription), requestedVariant)
                    let setting = await currentSetting()
                    if let oldVariant, setting == requestedVariant {
                        await revertSetting(requestedVariant, oldVariant)
                    }
                }
                let current = await currentSetting()
                target = current == self.state.snapshot().variant ? nil : current
            }
        }
    }
}

final class WhisperKitEngine: ObservableObject, TranscriptionEngine, @unchecked Sendable {
    let name = "WhisperKit"
    @MainActor @Published private(set) var statusText: String = "Not loaded"

    private let modelController = ModelReloadController<WhisperKit>()
    private let gate = SerialGate()
    private let downloadCoordinator: SpeechModelDownloadCoordinator
    @MainActor private weak var eventReceiver: (any SpeechModelEngineEventReceiving)?

    /// Whether the model has already been loaded (preloaded at launch, or lazily by an earlier
    /// call). Read by the live preview availability check — see PLAN 3 "Settings": when Cloud
    /// STT is the active engine, preview must never trigger a fresh multi-hundred-MB local model
    /// load just to satisfy a tick; it only runs if WhisperKit already happens to be loaded.
    /// This stays a cheap synchronous property for its SwiftUI and AppCoordinator call sites.
    var isLoaded: Bool { modelController.state.isLoaded }

    init(downloadCoordinator: SpeechModelDownloadCoordinator = .shared) {
        self.downloadCoordinator = downloadCoordinator
    }

    @MainActor
    func setEventReceiver(_ receiver: (any SpeechModelEngineEventReceiving)?) {
        eventReceiver = receiver
    }

    nonisolated static func shouldReload(loadedVariant: String?, requestedVariant: String?) -> Bool {
        guard let loadedVariant, let requestedVariant else { return false }
        return loadedVariant != requestedVariant
    }

    nonisolated static func failedReloadRevert(
        setting: String,
        failedRequested: String,
        loadedVariant: String?
    ) -> String? {
        guard setting == failedRequested else { return nil }
        return loadedVariant
    }

    /// Warms up the model outside the hot path (e.g. at app launch) so the first real
    /// dictation doesn't pay the load/download cost. Errors are swallowed into `statusText`
    /// (already visible in the menu bar) rather than thrown — nothing here is user-initiated.
    func preload() async {
        do {
            // Routed through `gate` too — otherwise a live preview tick firing mid-launch-load
            // (PLAN 3: preview starts as soon as a recording begins, independent of whether
            // preload has finished) could call `loadedKit()` a second time concurrently with
            // this one, racing two coordinator-backed download/load calls against the same cache.
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
        let kit = try await kitForTranscription()
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
                await setReadyStatus()
                throw CancellationError()
            }

            await setReadyStatus()
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            // When forced, the recorded language is always the forced code — never whatever
            // WhisperKit's decode result happens to report — mirroring CloudSTTEngine's contract.
            // See PLAN.md step 5.
            return TranscriptionOutput(text: text, language: forcedLanguage ?? results.first?.language ?? language)
        } catch {
            await setReadyStatus()
            throw error
        }
    }

    private func kitForTranscription() async throws -> WhisperKit {
        if let kit = modelController.state.snapshot().kit { return kit }
        return try await loadedKit()
    }

    private func loadedKit() async throws -> WhisperKit {
        if let kit = modelController.state.snapshot().kit { return kit }
        let variant = await AppSettings.shared.whisperModel
        return try await modelController.loadIfNeeded(
            requested: variant,
            loader: { try await self.loadModel(variant: $0) },
            event: { await self.emit($0, for: $1) },
            didInstall: { _ in await self.setReadyStatus() }
        )
    }

    func reload(to requested: String) async {
        await modelController.reload(
            to: requested,
            currentSetting: { await AppSettings.shared.whisperModel },
            revertSetting: { failed, previous in
                await MainActor.run {
                    if AppSettings.shared.whisperModel == failed {
                        AppSettings.shared.applyAutomaticWhisperModel(previous)
                    }
                }
            },
            loader: { variant in
                do { return try await self.loadModel(variant: variant) }
                catch {
                    await self.setStatus("Failed to load \(Self.displayName(for: variant)): \(error.localizedDescription)")
                    throw error
                }
            },
            event: { await self.emit($0, for: $1) },
            didInstall: { _ in await self.setReadyStatus() }
        )
    }

    private func loadModel(variant: String) async throws -> WhisperKit {
        let displayName = Self.displayName(for: variant)
        await setStatus("Checking for \(displayName)…")
        let folder = try await downloadCoordinator.download(variant: variant) { [weak self] progress in
            Task { await self?.reportDownloadProgress(progress, variant: variant, displayName: displayName) }
        }
        await setStatus("Loading \(displayName)…")
        let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .none, load: true, download: false)
        let kit = try await WhisperKit(config)
        return kit
    }

    private func reportDownloadProgress(_ progress: Double, variant: String, displayName: String) async {
        await emit(.downloading(progress: progress), for: variant)
        await setStatus("Downloading \(displayName)… \(Int(progress * 100))%")
    }

    private func emit(_ event: SpeechModelEngineEvent, for variant: String) async {
        await MainActor.run { eventReceiver?.receiveEngineEvent(event, for: variant) }
    }

    private func setReadyStatus() async {
        let variant = modelController.state.snapshot().variant
        await setStatus(variant.map { "Ready — \(Self.displayName(for: $0))" } ?? "Not loaded")
    }

    private static func displayName(for variant: String) -> String {
        SpeechModelCatalog.entry(for: variant)?.displayName ?? variant
    }

    @MainActor
    private func setStatus(_ text: String) {
        statusText = text
    }
}
