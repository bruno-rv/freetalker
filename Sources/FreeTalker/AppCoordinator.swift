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
    private static let logger = Logger(subsystem: "org.freetalker.app", category: "capture")

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
        } catch {
            lastError = "Mic error: \(error.localizedDescription)"
        }
    }

    private func handleKeyUp() {
        guard isRecording else { return }
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
        hud.show(text: "Processing…")

        // Snapshot the engine and Active Template synchronously, at key-release, before any
        // `await` — settings changed mid-transcription (e.g. during a long model download)
        // must not retroactively change which engine/template this dictation is processed
        // and recorded under. See Round 1 Codex finding 12.
        let engine = activeSTTEngine
        let engineName = engine.name
        let template = TemplateStore.shared.template(id: AppSettings.shared.activeTemplateID)
            ?? Template.builtIns.first!

        Task { await runPipeline(samples: samples, engine: engine, engineName: engineName, template: template) }
    }

    private func runPipeline(samples: [Float], engine: any TranscriptionEngine, engineName: String, template: Template) async {
        defer { isProcessing = false }

        do {
            let result = try await processDictation(samples: samples, engine: engine, engineName: engineName, template: template)
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
        processor: (any PostProcessor)? = nil,
        insert: (String) -> Bool = { Insertion.insert($0) },
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
            let processed = try await activeProcessor.process(transcript: transcription.text, template: template)
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never lose the user's words — fall back to the raw transcript if post-processing
            // returns empty output without throwing. See Round 1 Codex finding 3.
            refined = trimmed.isEmpty ? transcription.text : trimmed
        } catch {
            // Never lose the user's words — fall back to the raw transcript. See PLAN.md step 4.
            refined = transcription.text
        }

        let posted = insert(refined)

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
            let processed = try await processor.process(transcript: dictation.transcript, template: template)
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
