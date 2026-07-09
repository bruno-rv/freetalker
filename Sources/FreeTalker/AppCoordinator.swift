import AppKit
import AVFoundation
import Combine
import Foundation
import os

/// Central orchestrator: wires push-to-talk, capture, transcription, post-processing,
/// insertion, and Library recording into one pipeline. Also the source of truth for menu bar
/// status text. See PLAN.md "Approach" steps 2–6.
@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var lastError: String?
    /// Set while the global hotkey listener couldn't be started (missing Accessibility
    /// permission) and we're waiting for the user to grant it. See Round 1 Codex finding 8.
    @Published private(set) var hotKeyStatusText: String?

    let whisperEngine = WhisperKitEngine()
    let cloudSTTEngine = CloudSTTEngine()
    private let appleFMProcessor = AppleFMProcessor()
    private let cloudLLMProcessor = CloudLLMProcessor()

    private let hotKeyManager = HotKeyManager()
    private let audioCapture = AudioCapture()
    private let hud = HUDController()
    private var cancellables = Set<AnyCancellable>()
    private var permissionPollTimer: Timer?

    // ponytail: debug artifact for the live-mic silence investigation — always cheap (one
    // WAV write per dictation), kept permanently rather than behind a debug flag since it's
    // the fastest way to confirm what the mic tap actually delivered without asking the user
    // to reproduce anything. See CONTEXT.md.
    private static let logger = Logger(subsystem: "com.bruno.freetalker", category: "capture")

    var activeSTTEngine: any TranscriptionEngine {
        AppSettings.shared.sttEngine == .whisperKit ? whisperEngine : cloudSTTEngine
    }

    var engineStatusText: String {
        activeSTTEngine.statusText
    }

    private init() {
        // Forward engine status changes (e.g. WhisperKit download progress) so the menu bar
        // and Settings, which observe `AppCoordinator`, actually re-render live — not just
        // when the menu happens to reopen.
        whisperEngine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        cloudSTTEngine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        // Cheap catch-all: the user activating the app (opening Settings, the Library, even
        // just the menu bar popover focusing a window) re-checks the tap — catching
        // permissions granted in System Settings while the app was already running.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ensureHotKeyListening() }
        }
    }

    /// Single entry point that (re)creates the global hotkey event tap whenever it is dead.
    /// Called from: launch (App.swift), the 2s retry poll, hotkey reassignment (via
    /// `restartHotKeyListening`), and `NSApplication.didBecomeActiveNotification`.
    ///
    /// While the tap is dead, a 2s poll keeps retrying *unconditionally* — not gated on
    /// `AXIsProcessTrusted()`, because Input Monitoring can be the missing permission while
    /// Accessibility already reads trusted. The poll stops as soon as the tap is alive.
    func ensureHotKeyListening() {
        if hotKeyManager.isListening {
            hotKeyStatusText = nil
            stopHotKeyRetryPoll()
            return
        }
        hotKeyManager.onKeyDown = { [weak self] in self?.handleKeyDown() }
        hotKeyManager.onKeyUp = { [weak self] in self?.handleKeyUp() }
        if hotKeyManager.start(spec: AppSettings.shared.hotKeySpec) {
            hotKeyStatusText = nil
            stopHotKeyRetryPoll()
        } else {
            updateHotKeyStatusText()
            beginHotKeyRetryPollIfNeeded()
        }
    }

    /// Forces the tap to be recreated (the configured hotkey changed in Settings).
    func restartHotKeyListening() {
        hotKeyManager.stop()
        ensureHotKeyListening()
    }

    private func beginHotKeyRetryPollIfNeeded() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureHotKeyListening() }
        }
    }

    private func stopHotKeyRetryPoll() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    /// Sets an actionable hotkey status message, distinguishing two distinct tap-creation
    /// failures instead of a single generic "waiting" string:
    ///
    /// - Accessibility not trusted: the common case. Because `make app` ad-hoc signs with no
    ///   stable Team ID (`codesign -s -`), every rebuild that changes the binary produces a
    ///   different code signature, and TCC's Accessibility grant is tied to that signature —
    ///   so a grant made for a previous build silently stops applying after the next rebuild,
    ///   even though System Settings may still show FreeTalker's old entry checked. The message
    ///   tells the user to remove and re-add the entry in that case. See root cause H1
    ///   (empirically confirmed: rebuilding after any source change yields a new CDHash).
    /// - Accessibility trusted but the tap still failed: Input Monitoring (a separate TCC
    ///   service) is the remaining gate.
    private func updateHotKeyStatusText() {
        if Permissions.isAccessibilityTrusted() {
            hotKeyStatusText = "Input Monitoring not granted — enable FreeTalker in System Settings › Privacy & Security › Input Monitoring"
        } else {
            hotKeyStatusText = "Accessibility not granted — enable FreeTalker in System Settings › Privacy & Security › Accessibility. Already shown as on? Rebuilding changes FreeTalker's signature — remove it from the list and re-add it."
        }
    }

    /// Primes the microphone TCC prompt at launch (mirrors `Permissions.requestAccessibility()`
    /// in App.swift) so a first-time user isn't met with a silent capture from `.notDetermined`
    /// status the first time they hold push-to-talk. No-op if already determined (granted or
    /// denied) — the system only ever prompts once per determination. See live-mic silence
    /// root cause H1 (TCC grant orphaned by ad-hoc signature drift, same mechanism documented
    /// for Accessibility above).
    func primeMicrophonePermission() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        Permissions.requestMicrophoneAccess { _ in }
    }

    private func handleKeyDown() {
        guard !isRecording, !isProcessing else { return }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.logger.log("key down: micAuthorizationStatus=\(micStatus.rawValue, privacy: .public)")
        // Guard unconditionally rather than proceeding to record silence — a denied/stale TCC
        // grant lets AVAudioEngine start and "succeed" while delivering only zeros, which is
        // exactly what produces Whisper's silent-audio hallucination ("Thank you" for real
        // speech). See live-mic silence investigation, root cause H1.
        guard micStatus == .authorized else {
            hud.flash("Microphone not authorized — check System Settings › Privacy & Security › Microphone")
            return
        }
        do {
            try audioCapture.start(deviceUID: AppSettings.shared.microphoneDeviceUID)
            isRecording = true
            if let note = audioCapture.deviceFallbackNote {
                hud.show(text: note)
            } else {
                hud.show(text: "Recording…")
            }
            startLivePreviewIfNeeded()
        } catch {
            lastError = "Mic error: \(error.localizedDescription)"
        }
    }

    private func handleKeyUp() {
        guard isRecording else { return }
        // Cancel the preview loop immediately, before anything else — the final pipeline below
        // owns the buffer from here on. See PLAN 3 "Partial loop": "Key release: cancel loop
        // immediately, ignore any in-flight partial result, run existing final pipeline
        // untouched."
        stopLivePreview()
        isRecording = false
        let samples = audioCapture.stop()

        // Always cheap, always on: peak/RMS tells us in one line whether the mic tap delivered
        // real signal or near-silence, and the WAV lets us listen to exactly what was captured
        // — without it, "transcribed as Thank you" and "captured zero samples" are
        // indistinguishable from the log alone. See live-mic silence investigation.
        let (peak, rms) = AudioLevel.peakAndRMS(samples)
        Self.logger.log("capture stopped: samples=\(samples.count) peak=\(peak) rms=\(rms)")
        writeLastCaptureDebugArtifact(samples)

        guard !samples.isEmpty else {
            hud.hide()
            return
        }
        isProcessing = true

        // Snapshot the engine, frontmost app, and resolved Template synchronously, at
        // key-release, before any `await` — settings/app-switching mid-transcription (e.g.
        // during a long model download) must not retroactively change which engine/template
        // this dictation is processed and recorded under. See Round 1 Codex finding 12.
        //
        // Frontmost app is read here rather than at keyDown: this is the only existing snapshot
        // point in the pipeline (engine/template are already captured here, not at keyDown).
        // `insertionTarget` (bundle id, pid, and best-effort focused element/window — see
        // `InsertionTarget`) is carried through the pipeline and re-checked against the live
        // frontmost app/element immediately before paste (`Insertion.insert`'s `target`) — if
        // the user switched apps, or switched focus *within* the same app (a different Slack
        // channel, a different Mail draft), during the async transcribe/post-process work, the
        // synthetic ⌘V is skipped and the text is left on the pasteboard instead of landing in
        // the wrong place. See Codex finding: paste-target drift / same-app target drift.
        let engine = activeSTTEngine
        let engineName = engine.name
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmostApp?.bundleIdentifier
        let appName = frontmostApp?.localizedName
        let insertionTarget = Insertion.snapshotTarget(app: frontmostApp)
        let (template, ruleFired) = Self.resolveTemplate(
            bundleID: bundleID,
            rules: AppSettings.shared.appRules,
            templates: TemplateStore.shared.templates,
            activeTemplateID: AppSettings.shared.activeTemplateID
        )

        hud.show(text: ruleFired ? "Processing… (\(template.name))" : "Processing…")

        Task { await runPipeline(samples: samples, engine: engine, engineName: engineName, template: template, appName: appName, target: insertionTarget) }
    }

    /// Pure resolution of which Template a dictation should use: a rule mapping the snapshotted
    /// app's bundle id wins; a missing bundle id, no matching rule, or a rule pointing at a
    /// template id that no longer exists (deleted after the rule was created) all fall back to
    /// the Active Template — never crashes. `templates`/`activeTemplateID` are passed in (rather
    /// than read from the singletons directly) so this stays a pure function SelfCheck can drive
    /// with synthetic inputs. See PLAN 2 "Template resolution".
    nonisolated static func resolveTemplate(
        bundleID: String?,
        rules: [String: String],
        templates: [Template],
        activeTemplateID: String
    ) -> (template: Template, ruleFired: Bool) {
        let fallback = templates.first(where: { $0.id == activeTemplateID }) ?? Template.builtIns.first!
        guard let bundleID, let ruleTemplateID = rules[bundleID],
              let matched = templates.first(where: { $0.id == ruleTemplateID }) else {
            return (fallback, false)
        }
        return (matched, true)
    }

    // MARK: - Live preview (PLAN 3)

    /// Seconds between re-transcription ticks of the growing recording buffer. Periodic
    /// re-transcription (not WhisperKit's streaming API) — see PLAN 3 "Design".
    private static let livePreviewTickInterval: TimeInterval = 1.5
    /// 1s of 16kHz mono audio — a tick on anything shorter is mostly silence/noise and wastes a
    /// WhisperKit pass. See PLAN 3 "Partial loop".
    private static let livePreviewMinSamples = 16_000
    /// Constant-cost preview bound (Codex round-3 finding: early-stop is best-effort only —
    /// WhisperKit 0.18.0's pre-decode stages (logmel, encoder CoreML calls) aren't interruptible
    /// and the `TranscriptionCallback` fires from a low-priority detached task, so on a long
    /// recording a preview tick's `keyUp` cancellation can still delay the final transcription
    /// unboundedly. The hard bound is here, not in cancellation: every preview tick transcribes
    /// only the last `livePreviewWindowSeconds` of the buffer (see `AudioCapture.snapshotSuffix`),
    /// so a tick's worst-case cost — and therefore the final path's worst-case wait behind one —
    /// is constant regardless of how long the recording has run. The early-stop callback in
    /// `WhisperKitEngine` remains a second, opportunistic layer on top of this, not the bound
    /// itself.
    private static let livePreviewWindowSeconds: TimeInterval = 12
    /// 16kHz mono → 12s * 16,000 samples/s.
    private static let livePreviewWindowMaxSamples = Int(livePreviewWindowSeconds) * 16_000

    private var livePreviewTask: Task<Void, Never>?
    private var livePreviewGeneration = 0
    private var livePreviewInFlight = false
    private var lastLivePreviewText: String?

    /// Pure gating for a single tick: whether it's even worth taking a buffer snapshot and
    /// running a WhisperKit pass right now. No timers/audio/async — SelfCheck drives this
    /// directly. See PLAN 3 "Partial loop": skip if not recording, skip if a partial is already
    /// in flight (single in-flight gate, no backlog), skip if the buffer is still short.
    nonisolated static func shouldRunLivePreviewTick(isRecording: Bool, isPartialInFlight: Bool, sampleCount: Int, minSamples: Int) -> Bool {
        isRecording && !isPartialInFlight && sampleCount >= minSamples
    }

    /// Pure gating for whether a completed partial's text should actually reach the HUD: the
    /// recording must still be in progress AND still be the same one the tick was started for
    /// (generation match) — a fast keyUp→keyDown re-press bumps the generation, so a late result
    /// from the previous recording can't land on top of the new one even though `isRecording` is
    /// true again. See PLAN 3 "Failure modes to avoid".
    nonisolated static func shouldAcceptLivePreviewResult(isRecording: Bool, resultGeneration: Int, currentGeneration: Int) -> Bool {
        isRecording && resultGeneration == currentGeneration
    }

    /// Whether live preview should run at all for the current settings. Preview only ever
    /// transcribes with the local WhisperKit engine (never per-chunk cloud uploads — cost/
    /// latency/privacy, see PLAN 3 "Settings"): if WhisperKit itself is the active engine,
    /// preview is enabled by the toggle alone; if Cloud STT is the active engine, preview only
    /// runs when WhisperKit already happens to be loaded (never triggers a fresh load just for a
    /// tick).
    nonisolated static func isLivePreviewEnabled(settingEnabled: Bool, sttEngine: STTEngineKind, whisperKitLoaded: Bool) -> Bool {
        guard settingEnabled else { return false }
        return sttEngine == .whisperKit || whisperKitLoaded
    }

    /// Starts the periodic re-transcription loop for the recording that just began, if enabled.
    /// Bumps the generation counter so any result from a previous recording's loop (already
    /// cancelled, but possibly still finishing an in-flight tick) is discarded by
    /// `shouldAcceptLivePreviewResult` rather than shown here.
    private func startLivePreviewIfNeeded() {
        livePreviewGeneration += 1
        let generation = livePreviewGeneration
        livePreviewInFlight = false
        lastLivePreviewText = nil

        guard Self.isLivePreviewEnabled(
            settingEnabled: AppSettings.shared.livePreviewEnabled,
            sttEngine: AppSettings.shared.sttEngine,
            whisperKitLoaded: whisperEngine.isLoaded
        ) else { return }

        livePreviewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(AppCoordinator.livePreviewTickInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.runLivePreviewTick(generation: generation)
            }
        }
    }

    /// Cancels the loop. This is the opportunistic *second* layer, not the bound: the hard bound
    /// on a preview tick's worst-case cost is `AudioCapture.snapshotSuffix`'s constant-size copy
    /// plus `WhisperKitEngine`'s reduced preview `DecodingOptions`, both applied unconditionally
    /// before this ever runs. `whisperEngine.transcribe(allowEarlyCancel:)` in
    /// `runLivePreviewTick` additionally installs a per-token early-stop callback, so cancelling
    /// `livePreviewTask` here *can* abort an in-flight decode within one decode step — but
    /// WhisperKit 0.18.0's pre-decode stages (logmel, encoder CoreML calls) aren't interruptible
    /// and that callback fires from a low-priority detached task, so this alone cannot bound
    /// worst-case delay (Codex round-3 finding). With the window in place, worst-case final-path
    /// delay behind an in-flight tick is now ≈ one `previewWindowSeconds`-window WhisperKit pass,
    /// regardless of total recording length, whether or not this cancellation ever lands in
    /// time. Any result from a tick that still squeezes out a completion in that window is
    /// discarded anyway by `shouldAcceptLivePreviewResult` once `isRecording` flips false.
    private func stopLivePreview() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
    }

    private func runLivePreviewTick(generation: Int) async {
        // Bounded at the copy, not after (Codex round-4 finding): `snapshotSuffix` takes only
        // the last `livePreviewWindowMaxSamples` samples *inside* `samplesLock`, so a tick's
        // copy cost — and the COW risk it would otherwise impose on the tap thread's append path
        // — is constant regardless of total recording length. `totalCount` is the *whole*
        // buffer's size, used below for the <1s skip gate, which is about whether there's enough
        // real audio captured yet at all (a property of the whole recording, not of the window).
        let (window, totalCount) = audioCapture.snapshotSuffix(maxSamples: Self.livePreviewWindowMaxSamples)
        guard Self.shouldRunLivePreviewTick(
            isRecording: isRecording,
            isPartialInFlight: livePreviewInFlight,
            sampleCount: totalCount,
            minSamples: Self.livePreviewMinSamples
        ) else { return }

        livePreviewInFlight = true
        defer { livePreviewInFlight = false }

        // Runs through WhisperKitEngine's shared serial gate, so this never overlaps the final
        // transcription. `allowEarlyCancel: true` (preview-only — never passed by the final
        // pipeline) also selects `WhisperKitEngine`'s reduced preview `DecodingOptions` (see
        // `performTranscribe`) and lets `stopLivePreview`'s cancellation opportunistically abort
        // this decode within one decode step if it's already running when `keyUp` fires; a
        // cancelled/early-stopped attempt throws and lands here as `try?`. Errors are otherwise
        // non-fatal — the unchanged final pipeline still owns the real result; just let the next
        // tick retry.
        guard let result = try? await whisperEngine.transcribe(samples: window, allowEarlyCancel: true) else { return }

        guard Self.shouldAcceptLivePreviewResult(isRecording: isRecording, resultGeneration: generation, currentGeneration: livePreviewGeneration) else { return }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty partial leaves whatever the HUD already shows (e.g. "Recording…", or a device
        // fallback note) untouched, and only update when the text actually changed — avoids
        // flashing/resizing the pill every tick. See PLAN 3 "Failure modes to avoid".
        guard !text.isEmpty, text != lastLivePreviewText else { return }
        lastLivePreviewText = text
        hud.show(text: HUDController.tailTruncate(text))
    }

    private func runPipeline(samples: [Float], engine: any TranscriptionEngine, engineName: String, template: Template, appName: String?, target: InsertionTarget?) async {
        defer { isProcessing = false }

        do {
            let result = try await processDictation(samples: samples, engine: engine, engineName: engineName, template: template, appName: appName, target: target)
            // Busy state hides immediately on success; nothing terminal to show the user.
            // See Round 2 Codex finding 6.
            if result.posted {
                hud.hide()
            } else {
                hud.flash("Copied — paste manually")
            }
        } catch PipelineError.emptyTranscript {
            let saved = saveFailedAudio(samples)
            hud.flash(saved != nil ? "Transcription failed — audio saved" : "Transcription failed — audio could NOT be saved")
        } catch PipelineError.recordFailed(_) {
            hud.flash("Library save failed")
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
            let saved = saveFailedAudio(samples)
            hud.flash(saved != nil ? "Transcription failed — audio saved" : "Transcription failed — audio could NOT be saved")
        }
    }

    enum PipelineError: Error {
        case emptyTranscript
        case recordFailed(Error)
    }

    /// Core transcribe → post-process (with empty-refined fallback) → insert → record pipeline,
    /// extracted from `runPipeline` so it can be exercised with a fake engine/processor and
    /// without posting real CGEvents (`insert`) or touching the real Library database
    /// (`record`) in tests/SelfCheck. See Round 2 Codex finding 8.
    @discardableResult
    func processDictation(
        samples: [Float],
        engine: any TranscriptionEngine,
        engineName: String,
        template: Template,
        appName: String? = nil,
        target: InsertionTarget? = nil,
        processor: (any PostProcessor)? = nil,
        insert: (String, InsertionTarget?) -> Bool = { Insertion.insert($0, target: $1) },
        // ponytail: closure default (not a protocol/factory) keeps SelfCheck hermetic to a temp
        // DB instead of writing test rows into the user's real Library on every run.
        record: (_ language: String, _ template: String, _ transcript: String, _ refined: String, _ engine: String) throws -> Void = { language, template, transcript, refined, engine in
            try LibraryStore.shared.record(language: language, template: template, transcript: transcript, refined: refined, engine: engine)
        }
    ) async throws -> (transcript: String, refined: String, posted: Bool) {
        let transcription = try await engine.transcribe(samples: samples)
        guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.emptyTranscript
        }

        let activeProcessor: any PostProcessor = processor ?? (template.useCloud ? cloudLLMProcessor : appleFMProcessor)
        let refined: String
        do {
            let processed = try await activeProcessor.process(transcript: transcription.text, template: template, appName: appName)
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never lose the user's words — fall back to the raw transcript if post-processing
            // returns empty output without throwing. See Round 1 Codex finding 3.
            refined = trimmed.isEmpty ? transcription.text : trimmed
        } catch {
            // Never lose the user's words — fall back to the raw transcript. See PLAN.md step 4.
            refined = transcription.text
        }

        let posted = insert(refined, target)

        do {
            try record(transcription.language, template.name, transcription.text, refined, engineName)
        } catch {
            throw PipelineError.recordFailed(error)
        }

        return (transcription.text, refined, posted)
    }

    /// Persists captured audio that failed transcription (or transcribed to nothing) so the
    /// user's words aren't silently lost. Returns the saved file's URL, or nil if the save
    /// itself failed — callers must not claim the audio was saved unless this succeeds. No
    /// retry UI in v1 — the user can locate the WAV manually. See Round 1 Codex findings 1/2,
    /// Round 2 Codex finding 3.
    // ponytail: no retry/import UI + upgrade path: add a "Recover…" menu item that lists this
    // directory and re-runs the pipeline on a chosen file.
    @discardableResult
    private func saveFailedAudio(_ samples: [Float]) -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FreeTalker/failed-dictations", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // UUID prefix avoids two failures in the same second overwriting each other.
            // See Round 2 Codex finding 4.
            let uuidPrefix = UUID().uuidString.prefix(8)
            let name = "failed-\(Int(Date().timeIntervalSince1970))-\(uuidPrefix).wav"
            let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        } catch {
            lastError = "Failed to save recovery audio: \(error.localizedDescription)"
            return nil
        }
    }

    /// Overwrites `~/Library/Application Support/FreeTalker/last-dictation.wav` with the most
    /// recently captured audio, regardless of whether transcription succeeded. Cheap debug
    /// artifact for the live-mic silence investigation — lets the captured signal be inspected
    /// (played back, or peak/RMS-measured externally) without reproducing the bug interactively.
    private func writeLastCaptureDebugArtifact(_ samples: [Float]) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FreeTalker", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
            try data.write(to: dir.appendingPathComponent("last-dictation.wav"))
        } catch {
            Self.logger.error("failed to write last-dictation.wav: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-runs post-processing (only) on an existing Library entry's transcript with a
    /// different Template, inserting the result and appending a new Library row.
    /// See CONTEXT.md: "Re-process".
    func reprocess(dictation: Dictation, with template: Template) async {
        let processor: PostProcessor = template.useCloud ? cloudLLMProcessor : appleFMProcessor
        let refined: String
        do {
            // No known frontmost app for a historical re-process — appName: nil.
            let processed = try await processor.process(transcript: dictation.transcript, template: template, appName: nil)
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            // Same empty-refined fallback as processDictation. See Round 2 Codex finding 5.
            refined = trimmed.isEmpty ? dictation.transcript : trimmed
        } catch {
            refined = dictation.transcript
        }
        Insertion.insert(refined)
        do {
            try LibraryStore.shared.record(
                language: dictation.language,
                template: template.name,
                transcript: dictation.transcript,
                refined: refined,
                engine: dictation.engine,
                sourceID: dictation.sourceID ?? dictation.id
            )
        } catch {
            hud.flash("Library save failed")
        }
    }
}
