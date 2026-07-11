import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
    enum CaptureOwner: Equatable { case none, dictation, voiceEdit }
    enum CaptureDecision: Equatable { case start, stop, busy(CaptureOwner) }

    nonisolated static func captureStartDecision(current: CaptureOwner, requested: CaptureOwner) -> CaptureDecision {
        current == .none ? .start : .busy(current)
    }

    nonisolated static func capturePressDecision(current: CaptureOwner, pressed: CaptureOwner) -> CaptureDecision {
        if current == pressed { return .stop }
        return captureStartDecision(current: current, requested: pressed)
    }

    static let shared = AppCoordinator()

    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var lastError: String?
    /// Set while the global hotkey listener couldn't be started (missing Accessibility
    /// permission) and we're waiting for the user to grant it. See Round 1 Codex finding 8.
    @Published private(set) var hotKeyStatusText: String?

    /// Source of truth for the hands-free gesture (Amendment B): idle / pttRecording /
    /// locked. `isRecording` and `hotKeyManager.isRecording` (consulted synchronously by the
    /// event tap's Esc swallow decision) are kept in sync with it here, in one place, rather
    /// than at every call site that changes it.
    private var recordingState: RecordingState = .idle {
        didSet {
            let recording = recordingState != .idle
            if isRecording != recording { isRecording = recording }
            hotKeyManager.isRecording = recording
        }
    }
    /// Ties a `locked` recording's duration-cap timer fire to the recording it belongs to
    /// (Amendment B2) — bumped once per new recording (`beginCapture`). A `capReached` for a
    /// stale generation is a no-op, both defensively in `RecordingStateMachine.transition` and
    /// because `invalidateCapTimer()` already cancels the previous timer on every terminal
    /// transition.
    private var recordingGeneration = 0
    /// The current recording's key-down `CGEvent` timestamp (seconds since boot, from
    /// `HotKeyManager`'s tap callback — NOT `Date()` at handler time), used to compute
    /// `keyUp(elapsed:)` for the tap-vs-hold decision (`RecordingStateMachine.tapThreshold`).
    /// Deriving elapsed from the two event timestamps rather than wall-clock reads at handler
    /// time keeps the tap-vs-hold classification immune to capture-start latency or a delayed
    /// hop to the main actor. See `HotKeyManager.onKeyDown`/`onKeyUp` doc comments.
    private var keyDownTimestamp: TimeInterval?
    /// Fires `handleCapReached` when a `locked` recording hits its (clamped, snapshotted)
    /// duration cap. Invalidated on every terminal transition (stop/cancel/cap) — see B2.
    private var capTimer: Timer?
    private var lockedStartTime: Date?
    private var lockedCapSeconds: TimeInterval?
    /// Ticks the HUD's elapsed/cap display roughly once a second while `locked`.
    private var lockedHUDTimer: Timer?
    private var oneShotLanguage: String?

    let speechModelDownloadCoordinator: SpeechModelDownloadCoordinator
    let speechModelStore: SpeechModelStore
    let whisperEngine: WhisperKitEngine
    let cloudSTTEngine = CloudSTTEngine()
    private let appleFMProcessor = AppleFMProcessor()
    private let localContextProvider: any LocalContextProvider = AccessibilityLocalContextProvider()
    private let screenshotService: any ActiveWindowScreenshotCapturing = ActiveWindowScreenshotService()
    private let ocrService: any VisionOCRServicing = VisionOCRService()
    private let contextTargetSnapshotter = ContextTargetSnapshotter()
    private let selectionAccess: any SelectionAccessing = SelectionAccess()
    private(set) var pendingVoiceEditSelection: SelectionSnapshot?
    @Published private(set) var snippetStore: SnippetStore?
    @Published private(set) var snippetStoreInitializationError: String?
    private var voiceEditCoordinator: VoiceEditCoordinator?
    private var voiceEditWindow: NSWindow?
    private var voiceEditWindowDelegate: VoiceEditWindowDelegate?
    private var captureOwner: CaptureOwner = .none

    private let hotKeyManager = HotKeyManager()
    private let audioCapture = AudioCapture()
    private let hud = HUDController()
    private let recoveryStore: TranscriptionJobStore?
    let jobLibraryStore: JobLibraryStore?
    private var recoveryRunner: LocalJobRunner?
    private var cancellables = Set<AnyCancellable>()
    private var permissionPollTimer: Timer?

    private static let logger = Logger(subsystem: "com.bruno.freetalker", category: "capture")

    var activeSTTEngine: any TranscriptionEngine {
        AppSettings.shared.sttEngine == .whisperKit ? whisperEngine : cloudSTTEngine
    }

    var engineStatusText: String {
        activeSTTEngine.statusText
    }

    private init() {
        let downloadCoordinator = SpeechModelDownloadCoordinator.shared
        let modelStore = SpeechModelStore(coordinator: downloadCoordinator)
        speechModelDownloadCoordinator = downloadCoordinator
        speechModelStore = modelStore
        whisperEngine = WhisperKitEngine(downloadCoordinator: downloadCoordinator)
        let recoveryStore = try? Self.makeRecoveryStore()
        self.recoveryStore = recoveryStore
        do {
            snippetStore = try Self.makeSnippetStore()
            snippetStoreInitializationError = nil
        } catch {
            snippetStore = nil
            snippetStoreInitializationError = Self.snippetStoreErrorMessage(error)
        }
        jobLibraryStore = recoveryStore.map { JobLibraryStore(store: $0, recoveryDirectory: Self.recoveryDirectory) }
        whisperEngine.setEventReceiver(modelStore)
        modelStore.onAutomaticSelection = { [weak whisperEngine] target in
            guard let whisperEngine else { return }
            let kitLoaded = whisperEngine.isLoaded
            let localEngineSelected = AppSettings.shared.sttEngine == .whisperKit
            Task {
                await Self.routeAutomaticSpeechModelSelection(
                    target,
                    kitLoaded: kitLoaded,
                    localEngineSelected: localEngineSelected,
                    preload: { await whisperEngine.preload() },
                    reload: { await whisperEngine.reload(to: $0) }
                )
            }
        }
        // Forward engine status changes (e.g. WhisperKit download progress) so the menu bar
        // and Settings, which observe `AppCoordinator`, actually re-render live — not just
        // when the menu happens to reopen.
        whisperEngine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        cloudSTTEngine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        AppSettings.shared.$hotKeySpec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotKeyListening() }
            .store(in: &cancellables)
        AppSettings.shared.$redoHotKeySpec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotKeyListening() }
            .store(in: &cancellables)
        AppSettings.shared.$voiceEditHotKeySpec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotKeyListening() }
            .store(in: &cancellables)
        // Cheap catch-all: the user activating the app (opening Settings, the Library, even
        // just the menu bar popover focusing a window) re-checks the tap — catching
        // permissions granted in System Settings while the app was already running.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ensureHotKeyListening() }
        }
        // Amendment B3: clicking the HUD pill locks an in-progress PTT recording or stops a
        // locked one — wired once, not per-`ensureHotKeyListening()` call.
        hud.onPillClick = { [weak self] in self?.handlePillClick() }
        hud.onPanelCancel = { [weak self] in self?.handlePanelCancel() }
        hud.onPanelDone = { [weak self] in self?.handlePanelDone() }
        hud.onPanelRaw = { [weak self] in self?.handlePanelRaw() }
        hud.onPanelLanguage = { [weak self] code in self?.handlePanelOneShotLanguage(code) }
        hud.onPanelCycleTemplate = { [weak self] in self?.handlePanelCycleTemplate() }
        hud.onPanelLock = { [weak self] in self?.handlePillClick() }
    }

    func selectSpeechModelFromUser(_ variant: String) async {
        await Self.routeSpeechModelSelection(
            variant,
            setFromUser: { AppSettings.shared.setWhisperModelFromUser($0) },
            reload: { [whisperEngine] in await whisperEngine.reload(to: $0) }
        )
    }

    static func routeSpeechModelSelection(
        _ variant: String,
        setFromUser: (String) -> Void,
        reload: (String) async -> Void
    ) async {
        setFromUser(variant)
        await reload(variant)
    }

    static func routeAutomaticSpeechModelSelection(
        _ variant: String,
        kitLoaded: Bool,
        localEngineSelected: Bool,
        preload: () async -> Void,
        reload: (String) async -> Void
    ) async {
        if kitLoaded {
            await reload(variant)
        } else if localEngineSelected {
            await preload()
            await reload(variant)
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
        hotKeyManager.onKeyDown = { [weak self] eventSeconds in self?.handleKeyDown(eventSeconds: eventSeconds) }
        hotKeyManager.onKeyUp = { [weak self] eventSeconds in self?.handleKeyUp(eventSeconds: eventSeconds) }
        hotKeyManager.onEscape = { [weak self] in self?.handleEscape() }
        hotKeyManager.onRedoKeyDown = { [weak self] _ in self?.redoLast() }
        Self.configureVoiceEditHotKey(manager: hotKeyManager) { [weak self] in
            self?.handleVoiceEditHotKey()
        }
        if hotKeyManager.start(
            spec: AppSettings.shared.hotKeySpec,
            redoSpec: AppSettings.shared.redoHotKeySpec,
            voiceEditSpec: AppSettings.shared.voiceEditHotKeySpec
        ) {
            hotKeyStatusText = nil
            stopHotKeyRetryPoll()
        } else {
            updateHotKeyStatusText()
            beginHotKeyRetryPollIfNeeded()
        }
    }

    static func configureVoiceEditHotKey(manager: HotKeyManager, handler: @escaping @MainActor () -> Void) {
        manager.onVoiceEditKeyDown = { _ in handler() }
    }

    private func handleVoiceEditHotKey() {
        switch Self.capturePressDecision(current: captureOwner, pressed: .voiceEdit) {
        case .stop:
            finishVoiceEditInstructionRecording()
            return
        case .busy:
            hud.flash("Finish the current recording first")
            return
        case .start:
            break
        }
        Self.handleVoiceEditHotKey(
            selectionAccess: selectionAccess,
            pendingSelection: &pendingVoiceEditSelection,
            flash: { hud.flash($0) }
        )
        guard pendingVoiceEditSelection != nil else { return }
        beginVoiceEditInstructionRecording()
    }

    private func beginVoiceEditInstructionRecording() {
        guard Self.captureStartDecision(current: captureOwner, requested: .voiceEdit) == .start,
              !isProcessing else {
            hud.flash("Finish the current recording first")
            pendingVoiceEditSelection = nil
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.flash("Microphone not authorized — check System Settings")
            pendingVoiceEditSelection = nil
            return
        }
        do {
            try audioCapture.start(deviceUID: AppSettings.shared.microphoneDeviceUID)
            captureOwner = .voiceEdit
            isRecording = true
            hotKeyManager.isRecording = true
            hud.show(text: "Speak the edit instruction, then press Voice Edit again")
        } catch {
            pendingVoiceEditSelection = nil
            lastError = "Mic error: \(error.localizedDescription)"
        }
    }

    private func finishVoiceEditInstructionRecording() {
        let selection = pendingVoiceEditSelection
        pendingVoiceEditSelection = nil
        captureOwner = .none
        isRecording = false
        hotKeyManager.isRecording = false
        let samples = audioCapture.stop()
        guard let selection, !samples.isEmpty else {
            hud.flash("No voice instruction captured")
            return
        }
        isProcessing = true
        hud.show(text: "Transcribing instruction locally…")
        Task {
            defer { isProcessing = false }
            do {
                // Voice Edit is deliberately pinned to the on-device engine even when normal
                // dictation is configured for cloud STT.
                let transcription = try await whisperEngine.transcribe(samples: samples, forcedLanguage: nil)
                let instruction = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !instruction.isEmpty else {
                    hud.flash("No voice instruction recognized")
                    return
                }
                presentVoiceEdit(selection: selection, instruction: instruction)
                hud.hide()
            } catch {
                hud.flash("The local speech model could not transcribe the instruction")
            }
        }
    }

    private func presentVoiceEdit(selection: SelectionSnapshot, instruction: String) {
        closeVoiceEditWindow(clearCoordinator: true)
        let store = snippetStore
        let storeError = snippetStoreInitializationError ?? "storage initialization failed"
        let coordinator = VoiceEditCoordinator(
            selection: selection,
            instruction: instruction,
            selectionAccess: selectionAccess,
            snippetMatcher: { trigger in
                guard let store else {
                    throw VoiceEditSnippetError.storeUnavailable(storeError)
                }
                return try await store.match(trigger)
            }
        )
        voiceEditCoordinator = coordinator

        let presentation = VoiceEditPreviewWindowPresentation.make()
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: presentation.styleMask, backing: .buffered, defer: false
        )
        window.becomesKeyOnlyIfNeeded = presentation.becomesKeyOnlyIfNeeded
        window.isFloatingPanel = true
        window.title = "Voice Edit Preview"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VoiceEditPreviewView(coordinator: coordinator) { [weak self] in
            self?.closeVoiceEditWindow(clearCoordinator: true)
        })
        let delegate = VoiceEditWindowDelegate { [weak self] in
            self?.voiceEditCoordinator?.cancel()
            self?.voiceEditCoordinator = nil
            self?.voiceEditWindow = nil
            self?.voiceEditWindowDelegate = nil
        }
        window.delegate = delegate
        voiceEditWindowDelegate = delegate
        voiceEditWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        Task { await coordinator.begin() }
    }

    private func closeVoiceEditWindow(clearCoordinator: Bool) {
        if clearCoordinator { voiceEditCoordinator?.cancel() }
        voiceEditWindow?.delegate = nil
        voiceEditWindow?.close()
        voiceEditWindow = nil
        voiceEditWindowDelegate = nil
        if clearCoordinator { voiceEditCoordinator = nil }
    }

    static func handleVoiceEditHotKey(
        selectionAccess: any SelectionAccessing,
        pendingSelection: inout SelectionSnapshot?,
        flash: (String) -> Void
    ) {
        do {
            pendingSelection = try selectionAccess.capture()
        } catch let error as SelectionAccessError {
            pendingSelection = nil
            switch error {
            case .secureField:
                flash("Voice Edit is unavailable in secure fields")
            case .noEditableSelection, .noFrontmostApplication:
                flash("Select editable text first")
            case .targetChanged, .selectionChanged:
                flash("Selection changed — select text and try again")
            case .replacementFailed:
                flash("Could not access the selected text")
            }
        } catch {
            pendingSelection = nil
            flash("Could not access the selected text")
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

    // MARK: - Hands-free gesture (Amendment B)
    //
    // `handleKeyDown`/`handleKeyUp`/`handlePillClick`/`handleEscape`/`handleCapReached` each
    // drive one `RecordingEvent` through the pure `RecordingStateMachine.transition`, update
    // `recordingState`, then execute the `RecordingAction` it returned. The state machine itself
    // decides *whether* something happens (e.g. a keyDown while already `pttRecording` is a
    // no-op); these methods only ever perform the side effect the returned action names.

    private func handleKeyDown(eventSeconds: TimeInterval) {
        // A held-down previous recording still finishing (`isProcessing`) must not start a new
        // one — mirrors the pre-Amendment-B `!isProcessing` guard. `recordingState` is already
        // back to `.idle` by the time processing starts (set before the async pipeline `Task`
        // below), so the state machine alone can't tell these apart.
        guard !isProcessing, captureOwner != .voiceEdit else { return }
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .keyDown, currentGeneration: recordingGeneration)
        switch action {
        case .startCapture:
            keyDownTimestamp = eventSeconds
            if beginCapture() { recordingState = newState }
        case .stopAndTranscribe:
            recordingState = newState
            stopAndTranscribe()
        case .none, .enterLocked, .cancel:
            break
        }
    }

    private func handleKeyUp(eventSeconds: TimeInterval) {
        guard recordingState != .idle else { return }
        let elapsed = keyDownTimestamp.map { eventSeconds - $0 } ?? 0
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .keyUp(elapsed: elapsed), currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .enterLocked:
            enterLockedMode()
        case .stopAndTranscribe:
            stopAndTranscribe()
        case .none, .startCapture, .cancel:
            break
        }
    }

    /// Clicking the HUD pill (Amendment B3): locks an in-progress PTT recording, or stops a
    /// locked one. The FULL insertion target — frontmost app AND its (best-effort) focused AX
    /// element/window — is snapshotted BEFORE the click is processed, per B3 — the click itself
    /// (even though `HUDPanel` never becomes key/main) must never be able to redirect where the
    /// eventual paste lands. Snapshotting only the frontmost app here and deriving the AX
    /// element later, inside `stopAndTranscribe` (after the state-machine transition and its
    /// side effects have run), would leave a gap in which the focused element could drift before
    /// it's captured — defeating the same-app target-drift protection `InsertionTarget` exists
    /// for. See Codex finding: paste-target drift / same-app target drift.
    private func handlePillClick() {
        let preSnapshottedFrontmostApp = NSWorkspace.shared.frontmostApplication
        let preSnapshottedTarget = Insertion.snapshotTarget(app: preSnapshottedFrontmostApp)
        let preSnapshottedContextTarget = snapshotContextTarget(app: preSnapshottedFrontmostApp)
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .pillClick, currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .enterLocked:
            enterLockedMode()
        case .stopAndTranscribe:
            stopAndTranscribe(preSnapshotted: (app: preSnapshottedFrontmostApp, target: preSnapshottedTarget, contextTarget: preSnapshottedContextTarget))
        case .none, .startCapture, .cancel:
            break
        }
    }

    private func handleEscape() {
        if captureOwner == .voiceEdit {
            captureOwner = .none
            pendingVoiceEditSelection = nil
            isRecording = false
            hotKeyManager.isRecording = false
            _ = audioCapture.stop()
            hud.flash("Voice Edit cancelled")
            return
        }
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .esc, currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .cancel:
            cancelRecording()
        case .none, .startCapture, .enterLocked, .stopAndTranscribe:
            break
        }
    }

    enum PanelButton: Equatable {
        case cancel
        case done
        case raw
        case lock
    }

    nonisolated static func recordingEvent(for button: PanelButton) -> RecordingEvent {
        switch button {
        case .cancel: return .esc
        case .done, .raw: return .panelFinish
        case .lock: return .pillClick
        }
    }

    private func handlePanelCancel() { handleEscape() }

    private func handlePanelLock() { handlePillClick() }

    /// ✓ Done — stop+transcribe with post-processing.
    private func handlePanelDone() { handlePanelFinish(skipPostProcessing: false) }

    private func handlePanelRaw() { handlePanelFinish(skipPostProcessing: true) }

    private func handlePanelFinish(skipPostProcessing: Bool) {
        let preSnapshottedFrontmostApp = NSWorkspace.shared.frontmostApplication
        let preSnapshottedTarget = Insertion.snapshotTarget(app: preSnapshottedFrontmostApp)
        let preSnapshottedContextTarget = snapshotContextTarget(app: preSnapshottedFrontmostApp)
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: Self.recordingEvent(for: skipPostProcessing ? .raw : .done), currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .stopAndTranscribe:
            stopAndTranscribe(preSnapshotted: (app: preSnapshottedFrontmostApp, target: preSnapshottedTarget, contextTarget: preSnapshottedContextTarget), skipPostProcessing: skipPostProcessing)
        case .none, .startCapture, .enterLocked, .cancel:
            break
        }
    }

    enum OneShotLanguageEvent: Equatable {
        case panelLanguageTap(String)
        case clear
    }

    nonisolated static func nextOneShotLanguage(current: String?, event: OneShotLanguageEvent) -> String? {
        switch event {
        case .panelLanguageTap(let code): return current == code ? nil : code
        case .clear: return nil
        }
    }

    private func handlePanelOneShotLanguage(_ code: String) {
        guard recordingState != .idle else { return }
        oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .panelLanguageTap(code))
        updateRecordingPanel()
    }

    /// Pure "next template in store order" decision for the panel's template-cycle button —
    /// wraps around; a current id no longer present in the list (e.g. deleted mid-recording)
    /// falls back to the first template rather than crashing/no-op'ing forever.
    nonisolated static func nextTemplateID(current: String, templateIDsInOrder: [String]) -> String? {
        guard !templateIDsInOrder.isEmpty else { return nil }
        guard let index = templateIDsInOrder.firstIndex(of: current) else { return templateIDsInOrder.first }
        return templateIDsInOrder[(index + 1) % templateIDsInOrder.count]
    }

    private func handlePanelCycleTemplate() {
        guard recordingState != .idle else { return }
        guard let next = Self.nextTemplateID(current: AppSettings.shared.activeTemplateID, templateIDsInOrder: TemplateStore.shared.templates.map(\.id)) else { return }
        AppSettings.shared.activeTemplateID = next
        updateRecordingPanel()
    }

    /// A `locked` recording's duration-cap timer fired (Amendment B2). Routed through the state
    /// machine so a stale generation (superseded by a newer recording) is a no-op even if the
    /// timer somehow fired after `invalidateCapTimer()` should have cancelled it.
    private func handleCapReached(generation: Int) {
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .capReached(generation: generation), currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .stopAndTranscribe:
            stopAndTranscribe()
        case .none, .startCapture, .enterLocked, .cancel:
            break
        }
    }

    /// idle -> pttRecording side effect (unchanged from pre-Amendment-B PTT): starts audio
    /// capture. Returns false — leaving `recordingState` at `.idle` — on a mic-authorization or
    /// capture-start failure, so the caller never commits the state transition for a recording
    /// that never actually started.
    private func beginCapture() -> Bool {
        guard Self.captureStartDecision(current: captureOwner, requested: .dictation) == .start else {
            return false
        }
        oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.logger.log("key down: micAuthorizationStatus=\(micStatus.rawValue, privacy: .public)")
        // Guard unconditionally rather than proceeding to record silence — a denied/stale TCC
        // grant lets AVAudioEngine start and "succeed" while delivering only zeros, which is
        // exactly what produces Whisper's silent-audio hallucination ("Thank you" for real
        // speech). See live-mic silence investigation, root cause H1.
        guard micStatus == .authorized else {
            hud.flash("Microphone not authorized — check System Settings › Privacy & Security › Microphone")
            return false
        }
        do {
            try audioCapture.start(deviceUID: AppSettings.shared.microphoneDeviceUID)
            captureOwner = .dictation
            recordingGeneration += 1
            startLivePreviewIfNeeded()
            // startLivePreviewIfNeeded() just reset lastLivePreviewText to nil — seed it with the
            // device-fallback note (if any) so it's visible in the panel until real preview text
            // arrives.
            if let note = audioCapture.deviceFallbackNote {
                lastLivePreviewText = note
            }
            updateRecordingPanel()
            return true
        } catch {
            lastError = "Mic error: \(error.localizedDescription)"
            return false
        }
    }

    /// pttRecording -> locked side effect (Amendment B2/B3): snapshots the clamped duration cap
    /// for this recording's generation, (re)starts the cap timer and the HUD's elapsed-time
    /// ticker. Recording itself continues uninterrupted — no capture/preview changes.
    ///
    /// Both timers are added to the run loop's `.common` mode explicitly (rather than via
    /// `Timer.scheduledTimer`, which only schedules in `.default` mode) — `.default` mode is
    /// suspended while the run loop is tracking a menu, so a locked recording's duration cap
    /// (safety-critical: it's what stops an unattended recording) and its HUD ticker would both
    /// stall for as long as the user has any menu open (the app's own menu bar menu, a right-
    /// click context menu, anywhere).
    private func enterLockedMode() {
        invalidateCapTimer()
        let clampedMinutes = AppSettings.clampHandsFreeMaxMinutes(AppSettings.shared.handsFreeMaxMinutes)
        let capSeconds = TimeInterval(clampedMinutes * 60)
        lockedCapSeconds = capSeconds
        lockedStartTime = Date()
        let generation = recordingGeneration
        let newCapTimer = Timer(timeInterval: capSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleCapReached(generation: generation) }
        }
        RunLoop.main.add(newCapTimer, forMode: .common)
        capTimer = newCapTimer
        lockedHUDTimer?.invalidate()
        let newHUDTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRecordingPanel() }
        }
        RunLoop.main.add(newHUDTimer, forMode: .common)
        lockedHUDTimer = newHUDTimer
        updateRecordingPanel()
    }

    /// Rebuilds and re-renders the Recording Panel (Feature 3) from current coordinator state —
    /// called at capture start, on every live-preview tick, on every locked-mode timer tick, and
    /// whenever the one-shot language or Active Template selection changes, so the panel's own
    /// displayed state always agrees with what a stop-time resolution would actually pick. A
    /// no-op once the recording has ended (`recordingState == .idle`) — the terminal
    /// hide/flash calls own the HUD from that point on.
    private func updateRecordingPanel() {
        guard recordingState != .idle else { return }
        let isLocked: Bool
        let elapsed: TimeInterval
        let cap: TimeInterval
        if case .locked = recordingState, let start = lockedStartTime, let capSeconds = lockedCapSeconds {
            isLocked = true
            elapsed = Date().timeIntervalSince(start)
            cap = capSeconds
        } else {
            isLocked = false
            elapsed = 0
            cap = 0
        }
        let activeTemplateName = TemplateStore.shared.template(id: AppSettings.shared.activeTemplateID)?.name ?? "Template"
        let contextScope = AppSettings.shared.localContextScope
        let contextPermissionHint: String?
        if contextScope == .windowOCR {
            contextPermissionHint = switch Permissions.screenRecordingAuthorization() {
            case .granted: nil
            case .notGranted: "Screen Recording not granted for Window + local OCR"
            }
        } else if contextScope != .off, !Permissions.isAccessibilityTrusted() {
            contextPermissionHint = "Accessibility permission required"
        } else {
            contextPermissionHint = nil
        }
        let state = HUDController.RecordingPanelState(
            isLocked: isLocked,
            elapsed: elapsed,
            cap: cap,
            previewText: lastLivePreviewText.map { HUDController.tailTruncate($0, maxCharacters: 60) },
            activeTemplateName: activeTemplateName,
            localContextScopeName: contextScope.displayName,
            localContextPermissionHint: contextPermissionHint,
            oneShotLanguage: oneShotLanguage
        )
        hud.showRecordingPanel(state)
    }

    private func invalidateCapTimer() {
        capTimer?.invalidate()
        capTimer = nil
        lockedHUDTimer?.invalidate()
        lockedHUDTimer = nil
    }

    /// Terminal "stop" action (B4/B5) — shared by every stop trigger: classic PTT release,
    /// re-pressing the hotkey while locked, clicking the pill while locked, the duration cap
    /// firing while locked, and the Recording Panel's Done/Raw buttons (Feature 3). Reads the
    /// frontmost app/insertion-target snapshot at the moment this runs (i.e. at STOP time) unless
    /// `preSnapshotted` is supplied — used by the pill-click and panel-finish paths, whose FULL
    /// snapshot (app + AX element/window, not just the app) must be taken BEFORE the click itself
    /// is processed (B3). For the PTT path this is the same moment as before Amendment B:
    /// synchronous, at key-up, before any `await`. `skipPostProcessing` (Feature 3's "Raw"
    /// button) rides straight through to `processDictation` — the raw flag is pipeline config,
    /// not lifecycle, so it isn't part of the state machine.
    private func stopAndTranscribe(preSnapshotted: (app: NSRunningApplication?, target: InsertionTarget?, contextTarget: ContextTargetSnapshot)? = nil, skipPostProcessing: Bool = false) {
        let capturedOneShotLanguage = oneShotLanguage
        defer { oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear) }

        // The destination and context target are the first stop-time reads. Keep this before
        // audio teardown, logging, file I/O, and every async boundary so later focus changes
        // cannot redirect AX reads or OCR to another window.
        let frontmostApp = preSnapshotted?.app ?? NSWorkspace.shared.frontmostApplication
        let insertionTarget = preSnapshotted?.target ?? Insertion.snapshotTarget(app: frontmostApp)
        let contextTarget = preSnapshotted?.contextTarget ?? snapshotContextTarget(app: frontmostApp)

        invalidateCapTimer()
        stopLivePreview()
        captureOwner = .none
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

        // Snapshot the engine, frontmost app, and resolved Template synchronously, before any
        // `await` — settings/app-switching mid-transcription (e.g. during a long model download)
        // must not retroactively change which engine/template this dictation is processed and
        // recorded under. See Round 1 Codex finding 12.
        //
        // `insertionTarget` (bundle id, pid, and best-effort focused element/window — see
        // `InsertionTarget`) is carried through the pipeline and re-checked against the live
        // frontmost app/element immediately before paste (`Insertion.insert`'s `target`) — if
        // the user switched apps, or switched focus *within* the same app (a different Slack
        // channel, a different Mail draft), during the async transcribe/post-process work, the
        // synthetic ⌘V is skipped and the text is left on the pasteboard instead of landing in
        // the wrong place. See Codex finding: paste-target drift / same-app target drift.
        let engine = activeSTTEngine
        let engineName = engine.name
        let bundleID = frontmostApp?.bundleIdentifier
        let appName = frontmostApp?.localizedName
        let contextScope = AppSettings.shared.localContextScope
        let capturedContext = Self.captureApprovedContext(scope: contextScope, target: contextTarget, provider: localContextProvider)
        let contextCapture = contextScope == .off ? ContextCapture(
            context: LocalProcessingContext(
                appName: contextTarget.appName,
                bundleID: contextTarget.bundleID,
                windowTitle: contextTarget.windowTitle,
                text: ""
            ),
            limitation: nil
        ) : capturedContext
        let templates = TemplateStore.shared.templates
        let appRules = AppSettings.shared.appRules
        let activeTemplateID = AppSettings.shared.activeTemplateID
        let automaticStyleEnabled = AppSettings.shared.automaticStyleEnabled
        let processor = resolveActiveProcessor()
        let forcedLanguage = Self.resolveLanguage(
            oneShot: capturedOneShotLanguage,
            bundleID: bundleID,
            appLanguageRules: AppSettings.shared.appLanguageRules,
            pin: AppSettings.shared.languagePin
        )

        hud.show(text: Self.contextPermissionHint(for: contextCapture.limitation) ?? "Processing…")

        Task {
            let resolvedCapture = await resolveWindowOCR(
                scope: contextScope,
                capture: contextCapture,
                target: contextTarget
            )
            if let hint = Self.contextPermissionHint(for: resolvedCapture.limitation) {
                hud.show(text: hint)
            }
            let resolved = Self.resolveContextAwareTemplate(
                automaticStyleEnabled: automaticStyleEnabled,
                capture: resolvedCapture,
                rules: appRules,
                templates: templates,
                activeTemplateID: activeTemplateID
            )
            await runPipeline(
                samples: samples,
                engine: engine,
                engineName: engineName,
                template: resolved.template,
                appName: appName,
                target: insertionTarget,
                forcedLanguage: forcedLanguage,
                skipPostProcessing: skipPostProcessing,
                processor: processor,
                localContext: Self.localContextForProcessor(
                    isCloudConfigured: !(processor is AppleFMProcessor),
                    capture: resolvedCapture
                )
            )
        }
    }

    private func resolveWindowOCR(
        scope: LocalContextScope,
        capture: ContextCapture,
        target: ContextTargetSnapshot
    ) async -> ContextCapture {
        guard scope == .windowOCR, capture.limitation == nil else { return capture }
        do {
            var image: CGImage? = try await screenshotService.capture(target: target)
            let text = try await ocrService.recognizeText(in: image!)
            image = nil
            return ContextCapture(
                context: LocalProcessingContext(
                    appName: capture.context.appName,
                    bundleID: capture.context.bundleID,
                    windowTitle: capture.context.windowTitle,
                    text: text
                ),
                limitation: nil
            )
        } catch ActiveWindowScreenshotError.permissionNotGranted {
            return ContextCapture(context: capture.context, limitation: .screenRecordingPermissionNotGranted)
        } catch ActiveWindowScreenshotError.targetUnavailable {
            return ContextCapture(context: capture.context, limitation: .screenCaptureTargetUnavailable)
        } catch {
            return ContextCapture(context: capture.context, limitation: .screenCaptureFailed)
        }
    }

    private func snapshotContextTarget(app: NSRunningApplication?) -> ContextTargetSnapshot {
        contextTargetSnapshotter.snapshot(
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            processID: app?.processIdentifier ?? 0
        )
    }

    private func cancelRecording() {
        oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear)
        captureOwner = .none
        Self.performCancelRecording(
            stopCapture: { _ = self.audioCapture.stop() },
            cancelLivePreview: { self.stopLivePreview() },
            invalidateCapTimer: { self.invalidateCapTimer() },
            clearHUD: { self.hud.flash("Cancelled") }
        )
    }

    nonisolated static func performCancelRecording(
        stopCapture: () -> Void,
        cancelLivePreview: () -> Void,
        invalidateCapTimer: () -> Void,
        clearHUD: () -> Void
    ) {
        stopCapture()
        cancelLivePreview()
        invalidateCapTimer()
        clearHUD()
    }

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

    static func captureApprovedContext(
        scope: LocalContextScope,
        target: ContextTargetSnapshot,
        provider: any LocalContextProvider
    ) -> ContextCapture {
        guard scope != .off else { return .empty }
        return provider.capture(scope: scope, target: target)
    }

    nonisolated static func localContextForProcessor(
        isCloudConfigured: Bool,
        capture: ContextCapture
    ) -> LocalProcessingContext? {
        isCloudConfigured ? nil : capture.context
    }

    nonisolated static func contextPermissionHint(for limitation: ContextCaptureLimitation?) -> String? {
        switch limitation {
        case .accessibilityPermissionRequired:
            "Accessibility permission required for Local context"
        case .screenRecordingPermissionNotGranted:
            "Screen Recording not granted for Window + local OCR"
        case .screenCaptureTargetUnavailable:
            "Stopped window is no longer available for local OCR"
        case .screenCaptureFailed:
            "Window capture failed; continuing without local OCR"
        case nil:
            nil
        }
    }

    nonisolated static func resolveContextAwareTemplate(
        automaticStyleEnabled: Bool,
        capture: ContextCapture,
        rules: [String: String],
        templates: [Template],
        activeTemplateID: String
    ) -> (template: Template, ruleFired: Bool) {
        let manual = resolveTemplate(
            bundleID: capture.context.bundleID,
            rules: rules,
            templates: templates,
            activeTemplateID: activeTemplateID
        )
        guard !manual.ruleFired, automaticStyleEnabled else { return manual }
        return (
            AutomaticStyleClassifier().resolveTemplate(
                bundleID: capture.context.bundleID,
                windowTitle: capture.context.windowTitle,
                context: capture.context.text,
                rules: rules,
                templates: templates,
                activeTemplateID: activeTemplateID
            ),
            false
        )
    }

    nonisolated static func resolveLanguage(
        oneShot: String?,
        bundleID: String?,
        appLanguageRules: [String: String],
        pin: String
    ) -> String? {
        if let oneShot, let normalized = AppSettings.normalizeLanguageCode(oneShot) {
            return normalized
        }
        if let bundleID, let ruleValue = appLanguageRules[bundleID], let normalized = AppSettings.normalizeLanguageCode(ruleValue) {
            return normalized
        }
        // "auto" (or any other invalid value) normalizes to nil here — auto-detect — which is
        // exactly this function's own final fallback, so no extra branch is needed.
        return AppSettings.normalizeLanguageCode(pin)
    }

    nonisolated static func isCloudLLMConfigured(snapshot: CloudLLMSettingsSnapshot) -> Bool {
        snapshot.eligibility.isEligible
    }

    /// Same shape as `isCloudLLMConfigured` for Cloud STT's config: trimmed base URL and trimmed
    /// API key both non-empty. (Cloud STT has no user-configurable model field — `CloudSTTEngine`
    /// always sends `model: "whisper-1"` — so unlike the LLM check there's no model to validate.)
    /// Used to gate both the real Cloud STT engine selection contract and the Settings "Test
    /// connection" button's enabled state, so they can never disagree about what counts as
    /// "configured".
    nonisolated static func isCloudSTTConfigured(baseURL: String, key: String) -> Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Picks the Post-Processor for the dictation currently being handled: one `AppSettings`
    /// snapshot taken here, at selection time, decides both *whether* Cloud is used
    /// (`isCloudLLMConfigured`) and — if so — is threaded straight into the `CloudLLMProcessor`
    /// instance that runs it, so the two can never observe different settings. See Amendment A1.
    private func resolveActiveProcessor() -> any PostProcessor {
        let snapshot = AppSettings.shared.cloudLLMSnapshot
        return Self.isCloudLLMConfigured(snapshot: snapshot) ? CloudLLMProcessor(snapshot: snapshot) : appleFMProcessor
    }

    private static let livePreviewTickInterval: TimeInterval = 1.5
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

    nonisolated static func shouldRunLivePreviewTick(isRecording: Bool, isPartialInFlight: Bool, sampleCount: Int, minSamples: Int) -> Bool {
        isRecording && !isPartialInFlight && sampleCount >= minSamples
    }

    nonisolated static func shouldAcceptLivePreviewResult(isRecording: Bool, resultGeneration: Int, currentGeneration: Int) -> Bool {
        isRecording && resultGeneration == currentGeneration
    }

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
        guard let result = try? await whisperEngine.transcribe(samples: window, forcedLanguage: nil, allowEarlyCancel: true) else { return }

        guard Self.shouldAcceptLivePreviewResult(isRecording: isRecording, resultGeneration: generation, currentGeneration: livePreviewGeneration) else { return }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastLivePreviewText else { return }
        lastLivePreviewText = text
        // Recording Panel (Feature 3): the preview text is embedded inside the panel's own row
        // layout in both recording states — a tick must never replace that layout with a bare
        // text pill.
        updateRecordingPanel()
    }

    private func runPipeline(samples: [Float], engine: any TranscriptionEngine, engineName: String, template: Template, appName: String?, target: InsertionTarget?, forcedLanguage: String?, skipPostProcessing: Bool, processor: (any PostProcessor)? = nil, localContext: LocalProcessingContext? = nil) async {
        defer { isProcessing = false }

        do {
            let result = try await processDictation(samples: samples, engine: engine, engineName: engineName, template: template, appName: appName, target: target, forcedLanguage: forcedLanguage, skipPostProcessing: skipPostProcessing, processor: processor, localContext: localContext)
            if let fallbackReason = result.fallbackReason {
                logPostProcessingFallback(fallbackReason)
            }
            if !result.posted, result.fallbackReason != nil {
                hud.flash("Post-processing failed — raw transcript copied, paste manually (check API key/model in Settings)")
            } else if !result.posted {
                hud.flash(skipPostProcessing ? "Copied (raw) — paste manually" : "Copied — paste manually")
            } else if result.fallbackReason != nil {
                hud.flash("Cloud post-processing failed — used raw transcript (check API key/model in Settings)")
            } else if skipPostProcessing {
                hud.flash("Pasted (raw)")
            } else {
                hud.hide()
            }
        } catch PipelineError.emptyTranscript {
            let saved = await preserveFailedAudio(samples, failure: JobFailure(stage: .transcribing, message: "Empty transcript"))
            hud.flash(saved ? "Transcription failed — audio saved" : "Transcription failed — audio could NOT be saved")
        } catch PipelineError.recordFailed(_) {
            hud.flash("Library save failed")
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
            let saved = await preserveFailedAudio(samples, failure: JobFailure(stage: .transcribing, message: error.localizedDescription))
            hud.flash(saved ? "Transcription failed — audio saved" : "Transcription failed — audio could NOT be saved")
        }
    }

    enum PipelineError: Error {
        case emptyTranscript
        case recordFailed(Error)
    }

    enum PostProcessingFallbackReason {
        case error(Error)
        case emptyOutput
    }

    private func logPostProcessingFallback(_ reason: PostProcessingFallbackReason) {
        switch reason {
        case .error(let error):
            if case CloudLLMProcessor.CloudLLMError.badResponse(let provider, let status) = error {
                Self.logger.notice("post-processing fallback: \(provider, privacy: .public) returned HTTP \(status, privacy: .public)")
            } else {
                Self.logger.notice("post-processing fallback: \(String(describing: type(of: error)), privacy: .public)")
            }
        case .emptyOutput:
            Self.logger.notice("post-processing fallback: empty output")
        }
    }

    private func reportPostProcessingFallback(_ reason: PostProcessingFallbackReason) {
        logPostProcessingFallback(reason)
        hud.flash("Cloud post-processing failed — used raw transcript (check API key/model in Settings)")
    }

    @discardableResult
    func processDictation(
        samples: [Float],
        engine: any TranscriptionEngine,
        engineName: String,
        template: Template,
        appName: String? = nil,
        target: InsertionTarget? = nil,
        forcedLanguage: String? = nil,
        skipPostProcessing: Bool = false,
        processor: (any PostProcessor)? = nil,
        localContext: LocalProcessingContext? = nil,
        insert: (String, InsertionTarget?) -> Bool = { Insertion.insert($0, target: $1) },
        record: (_ language: String, _ template: String, _ transcript: String, _ refined: String, _ engine: String) throws -> Void = { language, template, transcript, refined, engine in
            try LibraryStore.shared.record(language: language, template: template, transcript: transcript, refined: refined, engine: engine)
        }
    ) async throws -> (transcript: String, refined: String, posted: Bool, fallbackReason: PostProcessingFallbackReason?) {
        let transcription = try await engine.transcribe(samples: samples, forcedLanguage: forcedLanguage)
        guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.emptyTranscript
        }

        let refined: String
        var fallbackReason: PostProcessingFallbackReason?
        let recordedTemplateName: String
        if skipPostProcessing {
            refined = transcription.text
            recordedTemplateName = TemplateStore.rawTranscriptTemplateName
        } else {
            let activeProcessor: any PostProcessor = processor ?? resolveActiveProcessor()
            do {
                let processed: String
                if let localProcessor = activeProcessor as? AppleFMProcessor, let localContext {
                    processed = try await localProcessor.process(
                        transcript: transcription.text,
                        template: template,
                        appName: appName,
                        context: localContext
                    )
                } else {
                    processed = try await activeProcessor.process(transcript: transcription.text, template: template, appName: appName)
                }
                let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
                // Never lose the user's words — fall back to the raw transcript if post-processing
                // returns empty output without throwing. See Round 1 Codex finding 3.
                if trimmed.isEmpty {
                    refined = transcription.text
                    fallbackReason = .emptyOutput
                } else {
                    refined = trimmed
                }
            } catch {
                refined = transcription.text
                fallbackReason = .error(error)
            }
            recordedTemplateName = template.name
        }

        let posted = insert(refined, target)

        do {
            try record(transcription.language, recordedTemplateName, transcription.text, refined, engineName)
        } catch {
            throw PipelineError.recordFailed(error)
        }

        return (transcription.text, refined, posted, fallbackReason)
    }

    private static let applicationSupportDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeTalker", isDirectory: true)
    }()

    private static var recoveryDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("failed-dictations", isDirectory: true)
    }

    private static func makeRecoveryStore() throws -> TranscriptionJobStore {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        return try TranscriptionJobStore(
            databaseURL: applicationSupportDirectory.appendingPathComponent("jobs.db"),
            clock: SystemJobClock()
        )
    }

    private static func makeSnippetStore() throws -> SnippetStore {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        return try SnippetStore(databaseURL: applicationSupportDirectory.appendingPathComponent("jobs.db"))
    }

    private static func snippetStoreErrorMessage(_ error: Error) -> String {
        String(describing: error)
    }

    func retrySnippetStoreInitialization() {
        do {
            snippetStore = try Self.makeSnippetStore()
            snippetStoreInitializationError = nil
        } catch {
            snippetStore = nil
            snippetStoreInitializationError = Self.snippetStoreErrorMessage(error)
        }
    }

    private func preserveFailedAudio(_ samples: [Float], failure: JobFailure) async -> Bool {
        guard let jobLibraryStore else { return false }
        do {
            _ = try await jobLibraryStore.preserve(
                samples: samples,
                metadata: RecoveryMetadata(capturedAt: Date(), failure: failure)
            )
            return true
        } catch {
            lastError = "Failed to save recovery audio: \(error.localizedDescription)"
            return false
        }
    }

    func launchRecoveryWorkflows() async {
        guard let recoveryStore else { return }
        let pipeline = RecoveryRetryPipeline(
            directory: Self.recoveryDirectory,
            store: recoveryStore,
            processDictation: { [weak self] samples, configuration in
                guard let self else { throw CancellationError() }
                return try await self.processRecoveredDictation(samples: samples, configuration: configuration)
            },
            errorStage: { error in
                if case PipelineError.recordFailed = error { return .persisting }
                return .transcribing
            }
        )
        let runner = LocalJobRunner(
            store: recoveryStore,
            kind: .recovery,
            executorFinalizesJob: true,
            finalizationFailure: pipeline.failFinalization,
            didChange: { [weak jobLibraryStore] _ in try? await jobLibraryStore?.refresh() }
        ) { job, token in
            try await pipeline.execute(jobID: job.id, configuration: nil, cancellation: token)
        }
        recoveryRunner = runner
        jobLibraryStore?.configureRetry { [weak runner] id in await runner?.enqueue(id) }
        await pipeline.retryPendingSourceCleanup()
        _ = try? await recoveryStore.recoverInterruptedJobs(kind: .recovery)
        _ = try? await RecoveryRetentionService(directory: Self.recoveryDirectory, store: recoveryStore)
            .purgeExpired(now: Date(), retention: AppSettings.shared.recoveryRetention)
        await runner.resumeQueuedJobs()
        try? await jobLibraryStore?.refresh()
    }

    private func processRecoveredDictation(
        samples: [Float],
        configuration: AttemptConfiguration
    ) async throws -> RecoveryDictation {
        if let model = configuration.speechModel { await whisperEngine.reload(to: model) }
        let template = TemplateStore.shared.templates.first {
            $0.id == configuration.template || $0.name == configuration.template
        } ?? TemplateStore.shared.template(id: AppSettings.shared.activeTemplateID) ?? Template.builtIns[0]
        let engine = activeSTTEngine
        let result = try await processDictation(
            samples: samples,
            engine: engine,
            engineName: AppSettings.shared.sttEngine.rawValue,
            template: template,
            forcedLanguage: configuration.language,
            insert: { _, _ in false }
        )
        return RecoveryDictation(
            language: configuration.language ?? "detected",
            template: template.name,
            transcript: result.transcript,
            refined: result.refined,
            engine: AppSettings.shared.sttEngine.rawValue
        )
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

    func reprocess(dictation: Dictation, with template: Template) async {
        let processor: PostProcessor = resolveActiveProcessor()
        let refined: String
        var fallbackReason: PostProcessingFallbackReason?
        do {
            // No known frontmost app for a historical re-process — appName: nil.
            let processed = try await processor.process(transcript: dictation.transcript, template: template, appName: nil)
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            // Same empty-refined fallback as processDictation. See Round 2 Codex finding 5.
            if trimmed.isEmpty {
                refined = dictation.transcript
                fallbackReason = .emptyOutput
            } else {
                refined = trimmed
            }
        } catch {
            refined = dictation.transcript
            fallbackReason = .error(error)
        }
        Insertion.insert(refined)
        if LibraryStore.shared.exists(id: dictation.id) == false {
            return
        }
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
            return
        }
        if let fallbackReason {
            reportPostProcessingFallback(fallbackReason)
        }
    }

    enum RedoLastAction: Equatable {
        /// `isRecording` or `isProcessing` was true — redo is silently ignored while active.
        case ignored
        case nothingToRedo
        case libraryUnavailable
        case insert(refined: String)
    }

    /// Guard + outcome decision for `redoLast()`. `fetchResult` is only consulted once the
    /// active-recording/processing guard passes — matching `redoLast()`, which skips the
    /// Database lookup entirely while active.
    nonisolated static func redoLastAction(isRecording: Bool, isProcessing: Bool, fetchResult: Result<Dictation?, Error>) -> RedoLastAction {
        guard !isRecording, !isProcessing else { return .ignored }
        switch fetchResult {
        case .failure:
            return .libraryUnavailable
        case .success(let dictation):
            guard let dictation else { return .nothingToRedo }
            return .insert(refined: dictation.refined)
        }
    }

    /// The HUD message `redoLast()` shows after attempting to insert the newest Library entry's
    /// Refined Output — mirrors the existing "posted vs. not" wording `runPipeline` uses for the
    /// same distinction (manual-paste fallback, `Insertion.insert`'s `Bool` result), so a failed
    /// synthetic paste (text left on the pasteboard only) is never reported to the user as if it
    /// had actually landed at the cursor. See Round 1 Codex finding 9.
    nonisolated static func redoLastResultMessage(posted: Bool) -> String {
        posted ? "Redone" : "Copied — paste manually"
    }

    func redoLast() {
        // Skip the Database lookup entirely while active — `redoLastAction` ignores
        // `fetchResult` in that branch anyway, so `.success(nil)` here is just a placeholder.
        let fetchResult: Result<Dictation?, Error> = (isRecording || isProcessing)
            ? .success(nil)
            : Result { try LibraryStore.shared.latestDictation() }
        switch Self.redoLastAction(isRecording: isRecording, isProcessing: isProcessing, fetchResult: fetchResult) {
        case .ignored:
            break
        case .nothingToRedo:
            hud.flash("Nothing to redo")
        case .libraryUnavailable:
            hud.flash("Library unavailable")
        case .insert(let refined):
            let posted = Insertion.insert(refined)
            hud.flash(Self.redoLastResultMessage(posted: posted))
        }
    }
}

@MainActor
private final class VoiceEditWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
