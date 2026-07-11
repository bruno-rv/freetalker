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
    /// Recording Panel one-shot language choice (CONTEXT.md "Language Pin", PLAN.md step 12):
    /// beats the app rule AND the pin, but only for the in-flight Dictation. Set/cleared only
    /// through `Self.nextOneShotLanguage` (see below) so every touch point — set, tap-again-
    /// clears, and the three clear sites (stop, cancel, new recording) — goes through the same
    /// pure decision SelfCheck exercises directly.
    private var oneShotLanguage: String?

    let speechModelDownloadCoordinator: SpeechModelDownloadCoordinator
    let speechModelStore: SpeechModelStore
    let whisperEngine: WhisperKitEngine
    let cloudSTTEngine = CloudSTTEngine()
    private let appleFMProcessor = AppleFMProcessor()

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
        let downloadCoordinator = SpeechModelDownloadCoordinator.shared
        let modelStore = SpeechModelStore(coordinator: downloadCoordinator)
        speechModelDownloadCoordinator = downloadCoordinator
        speechModelStore = modelStore
        whisperEngine = WhisperKitEngine(downloadCoordinator: downloadCoordinator)
        whisperEngine.setEventReceiver(modelStore)
        modelStore.onAutomaticSelection = { [weak whisperEngine] target in
            guard let whisperEngine else { return }
            Task {
                await Self.routeAutomaticSpeechModelSelection(
                    target,
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
        // Central hotkey re-plumb (Round 1 Codex finding 6): every call site that changes
        // `AppSettings.shared.hotKeySpec`/`redoHotKeySpec` used to have to remember to also call
        // `restartHotKeyListening()` itself (SettingsView's Change…/Clear buttons did, three
        // times over) — a direct assignment from anywhere else would silently leave the event
        // tap's matchers stale. Subscribing here instead makes AppCoordinator itself the one
        // place either setting's change re-plumbs the tap, so no call site needs to remember to;
        // the matching manual calls in SettingsView are removed. `dropFirst()` skips the initial
        // replay each `@Published` projected publisher sends on subscribe.
        //
        // Not exercised by SelfCheck: like `ensureHotKeyListening()`/`hotKeyManager.start()`
        // elsewhere in this file, the callback attempts a real `CGEventTap` creation —
        // SelfCheck never triggers that (see `hotKeyChecks()`/`redoLastChecks()`, which only
        // drive the pure `HotKeyMatcher`/`HotKeySpec` decision logic), so no check assigns to
        // `AppSettings.shared.hotKeySpec`/`redoHotKeySpec` directly; doing so would fire this
        // subscription against `AppCoordinator.shared`, which is already live by the time
        // SelfCheck runs (see the pipeline contract check above).
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
        // Cheap catch-all: the user activating the app (opening Settings, the Library, even
        // just the menu bar popover focusing a window) re-checks the tap — catching
        // permissions granted in System Settings while the app was already running.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ensureHotKeyListening() }
        }
        // Amendment B3: clicking the HUD pill locks an in-progress PTT recording or stops a
        // locked one — wired once, not per-`ensureHotKeyListening()` call.
        hud.onPillClick = { [weak self] in self?.handlePillClick() }
        // Recording Panel (Feature 3): each control's own callback, wired once — see
        // PLAN.md step 9/10.
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
        preload: () async -> Void,
        reload: (String) async -> Void
    ) async {
        await preload()
        await reload(variant)
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
        if hotKeyManager.start(spec: AppSettings.shared.hotKeySpec, redoSpec: AppSettings.shared.redoHotKeySpec) {
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
        guard !isProcessing else { return }
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
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .pillClick, currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .enterLocked:
            enterLockedMode()
        case .stopAndTranscribe:
            stopAndTranscribe(preSnapshotted: (app: preSnapshottedFrontmostApp, target: preSnapshottedTarget))
        case .none, .startCapture, .cancel:
            break
        }
    }

    /// Esc while recording (either mode) cancels — the event tap only forwards Esc here while
    /// actually recording (see `HotKeyManager.shouldSwallowEscape`), so this fires only when
    /// `recordingState != .idle` in practice; routed through the state machine regardless, for a
    /// single source of truth. See PLAN.md Amendment B1.
    private func handleEscape() {
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .esc, currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .cancel:
            cancelRecording()
        case .none, .startCapture, .enterLocked, .stopAndTranscribe:
            break
        }
    }

    // MARK: - Recording Panel (Feature 3)
    //
    // Every panel button that can stop/lock/cancel the recording routes through
    // `RecordingStateMachine.transition` from the CURRENT state, via the pure
    // `recordingEvent(for:)` mapping below — so a stale/double click (the state already back at
    // idle by the time it's handled) always resolves to `.none` from the same table
    // `handsFreeChecks`/`panelActionRoutingChecks` cover, rather than a bespoke per-button guard.
    // See PLAN.md step 9/10.

    /// Which `RecordingEvent` a Recording Panel button press maps to — the routing table
    /// SelfCheck drives directly against `RecordingStateMachine.transition`. EN/PT and the
    /// template-cycle button aren't lifecycle transitions (they don't stop/lock/cancel a
    /// recording) — they're metadata toggles gated on "a recording is in progress", handled by
    /// their own methods below rather than through this table.
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

    /// ✕ Cancel — same esc/cancel path as pressing Esc while recording. See PLAN.md step 9.
    private func handlePanelCancel() { handleEscape() }

    /// 🔒 Lock — visible only in `pttRecording` (PLAN.md step 9); the only panel control mapped
    /// to `pillClick`, reusing `handlePillClick`'s existing pre-snapshot + enterLocked path.
    private func handlePanelLock() { handlePillClick() }

    /// ✓ Done — stop+transcribe with post-processing.
    private func handlePanelDone() { handlePanelFinish(skipPostProcessing: false) }

    /// "Raw" — stop+transcribe verbatim (Post-Processor never invoked). See PLAN.md step 11.
    private func handlePanelRaw() { handlePanelFinish(skipPostProcessing: true) }

    /// Shared Done/Raw implementation (PLAN.md step 10): Done/Raw CANNOT reuse `pillClick` —
    /// from `pttRecording`, `pillClick` LOCKS rather than stopping — so this routes `.panelFinish`
    /// instead, with the same pre-snapshot discipline as `handlePillClick` (InsertionTarget
    /// captured BEFORE the state-machine transition and its side effects, for the same
    /// paste-target-drift reason).
    private func handlePanelFinish(skipPostProcessing: Bool) {
        let preSnapshottedFrontmostApp = NSWorkspace.shared.frontmostApplication
        let preSnapshottedTarget = Insertion.snapshotTarget(app: preSnapshottedFrontmostApp)
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: Self.recordingEvent(for: skipPostProcessing ? .raw : .done), currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .stopAndTranscribe:
            stopAndTranscribe(preSnapshotted: (app: preSnapshottedFrontmostApp, target: preSnapshottedTarget), skipPostProcessing: skipPostProcessing)
        case .none, .startCapture, .enterLocked, .cancel:
            break
        }
    }

    /// Pure decision for what `oneShotLanguage` should become after each lifecycle event PLAN.md
    /// step 12 names: a panel EN/PT tap sets/toggles it (tapping the already-active choice clears
    /// it back to standing behavior); a stop (`stopAndTranscribe`, every terminal path including
    /// the empty-samples early return), a cancel, or a new recording starting all clear it back
    /// to nil. Every real touch point below calls this — not a re-derived mirror — so SelfCheck's
    /// coverage is of the actual production decision.
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

    /// EN | PT one-shot buttons (PLAN.md step 9): sets/clears `oneShotLanguage` for the IN-FLIGHT
    /// Dictation only. Gated on "a recording is in progress" — a stale press after the recording
    /// already ended must not set state for a future, unrelated Dictation.
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

    /// Template-cycle button (PLAN.md step 9): advances the GLOBAL Active Template through the
    /// store's order — not a one-shot; the stop-time template resolution read makes it apply
    /// naturally to the in-flight Dictation. Gated the same way as the language buttons.
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
        // Reset for the new Dictation (PLAN.md step 12) — a one-shot choice never leaks across
        // recordings.
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
        let state = HUDController.RecordingPanelState(
            isLocked: isLocked,
            elapsed: elapsed,
            cap: cap,
            previewText: lastLivePreviewText.map { HUDController.tailTruncate($0, maxCharacters: 60) },
            activeTemplateName: activeTemplateName,
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
    private func stopAndTranscribe(preSnapshotted: (app: NSRunningApplication?, target: InsertionTarget?)? = nil, skipPostProcessing: Bool = false) {
        // Consumed into the forced-language snapshot below, before the pipeline `Task` starts;
        // cleared on EVERY terminal path of this function via `defer` (including the
        // empty-samples early return just below) so a one-shot choice never leaks into the next
        // Dictation. See PLAN.md step 12.
        let capturedOneShotLanguage = oneShotLanguage
        defer { oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear) }

        invalidateCapTimer()
        // Cancel the preview loop immediately, before anything else — the final pipeline below
        // owns the buffer from here on. See PLAN 3 "Partial loop": "Key release: cancel loop
        // immediately, ignore any in-flight partial result, run existing final pipeline
        // untouched."
        stopLivePreview()
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
        let frontmostApp = preSnapshotted?.app ?? NSWorkspace.shared.frontmostApplication
        let bundleID = frontmostApp?.bundleIdentifier
        let appName = frontmostApp?.localizedName
        let insertionTarget = preSnapshotted?.target ?? Insertion.snapshotTarget(app: frontmostApp)
        let (template, ruleFired) = Self.resolveTemplate(
            bundleID: bundleID,
            rules: AppSettings.shared.appRules,
            templates: TemplateStore.shared.templates,
            activeTemplateID: AppSettings.shared.activeTemplateID
        )
        // Language Pin resolution (CONTEXT.md "Language Pin"): resolved here, at stop time,
        // using the same already-snapshotted `bundleID` template resolution just used — passed
        // as a parameter through the pipeline, never re-read from AppSettings mid-transcribe. See
        // PLAN.md step 4/12.
        let forcedLanguage = Self.resolveLanguage(
            oneShot: capturedOneShotLanguage,
            bundleID: bundleID,
            appLanguageRules: AppSettings.shared.appLanguageRules,
            pin: AppSettings.shared.languagePin
        )

        hud.show(text: ruleFired ? "Processing… (\(template.name))" : "Processing…")

        Task { await runPipeline(samples: samples, engine: engine, engineName: engineName, template: template, appName: appName, target: insertionTarget, forcedLanguage: forcedLanguage, skipPostProcessing: skipPostProcessing) }
    }

    /// Terminal `cancelRecording` action (B1a) — the production call site, wired to the real
    /// audio/HUD/timer objects. See `performCancelRecording` for the pure, injectable version
    /// SelfCheck exercises.
    private func cancelRecording() {
        oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear)
        Self.performCancelRecording(
            stopCapture: { _ = self.audioCapture.stop() },
            cancelLivePreview: { self.stopLivePreview() },
            invalidateCapTimer: { self.invalidateCapTimer() },
            clearHUD: { self.hud.flash("Cancelled") }
        )
    }

    /// Pure execution of the `cancelRecording` side-effect set (B1a): stop audio capture, cancel
    /// the live preview loop, invalidate the cap timer, and clear/flash the HUD — in that order,
    /// discarding whatever `stopCapture` returns. Deliberately does NOT call transcribe/insert/
    /// record — no transcription, no Library entry, no failed-audio save. Exposed as a `static`
    /// so SelfCheck can assert exactly this side-effect set fires, via injected hooks, without a
    /// live `AppCoordinator`/real audio/HUD/timers. See PLAN.md Amendment B1a.
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

    /// Pure Language Pin resolution (CONTEXT.md "Language Pin"): returns nil for auto-detect, or
    /// a forced "en"/"pt" code. Precedence: one-shot (panel) > app rule > pin > auto. Each
    /// candidate is normalized INDEPENDENTLY (`AppSettings.normalizeLanguageCode`: trim/lowercase,
    /// must be "en"/"pt") — an invalid candidate falls through to the next rather than blocking a
    /// valid one further down the chain (an invalid one-shot never blocks a valid rule/pin; an
    /// invalid rule never blocks a valid pin). A nil `bundleID` skips the app-rule step entirely.
    /// See PLAN.md step 4.
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

    /// Pure global routing rule (Amendment A1, replacing the removed per-Template
    /// `Template.useCloud` toggle): the Cloud Post-Processor is used for every Template — never
    /// selected per Template — iff the active provider's config is complete: trimmed base URL
    /// non-empty, trimmed model non-empty, and a non-empty provider-scoped Keychain key present.
    /// Any one missing falls back to the on-device `AppleFMProcessor`. Takes the same
    /// `CloudLLMSettingsSnapshot` passed into `CloudLLMProcessor.process`, so the routing decision
    /// and the request it drives can never disagree. See PLAN.md Amendment A.
    nonisolated static func isCloudLLMConfigured(snapshot: CloudLLMSettingsSnapshot) -> Bool {
        let baseURL = snapshot.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = snapshot.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = snapshot.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !baseURL.isEmpty && !model.isEmpty && !key.isEmpty
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
        guard let result = try? await whisperEngine.transcribe(samples: window, forcedLanguage: nil, allowEarlyCancel: true) else { return }

        guard Self.shouldAcceptLivePreviewResult(isRecording: isRecording, resultGeneration: generation, currentGeneration: livePreviewGeneration) else { return }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty partial leaves whatever the HUD already shows (e.g. "Recording…", or a device
        // fallback note) untouched, and only update when the text actually changed — avoids
        // flashing/resizing the pill every tick. See PLAN 3 "Failure modes to avoid".
        guard !text.isEmpty, text != lastLivePreviewText else { return }
        lastLivePreviewText = text
        // Recording Panel (Feature 3): the preview text is embedded inside the panel's own row
        // layout in both recording states — a tick must never replace that layout with a bare
        // text pill.
        updateRecordingPanel()
    }

    private func runPipeline(samples: [Float], engine: any TranscriptionEngine, engineName: String, template: Template, appName: String?, target: InsertionTarget?, forcedLanguage: String?, skipPostProcessing: Bool) async {
        defer { isProcessing = false }

        do {
            let result = try await processDictation(samples: samples, engine: engine, engineName: engineName, template: template, appName: appName, target: target, forcedLanguage: forcedLanguage, skipPostProcessing: skipPostProcessing)
            if let fallbackReason = result.fallbackReason {
                logPostProcessingFallback(fallbackReason)
            }
            // The manual-paste notice is the actionable signal that the user's words are on the
            // clipboard, not inserted — it must never be silently clobbered by the (less urgent)
            // post-processing fallback notice. Neither must it silently clobber the fallback
            // notice the other way: when BOTH conditions hold, a single-condition message would
            // drop half the story (either "why is this the raw transcript" or "why do I need to
            // paste manually"), so that case gets its own combined message instead of falling
            // through the two single-condition branches below. Busy state otherwise hides
            // immediately on success; nothing terminal to show the user. See Round 2 Codex
            // finding 6, PLAN.md step 8. Raw dictations (Feature 3, `skipPostProcessing`) never
            // have a fallback reason (the Post-Processor is never invoked) — their own terminal
            // message ("Pasted (raw)") only applies on the success path.
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

    /// Why post-processing fell back to the raw transcript — a thrown error, or output that
    /// came back empty/whitespace-only without throwing. Reported (logged + surfaced) by the two
    /// call sites (`runPipeline`, `reprocess`) rather than inside `processDictation` itself, so
    /// SelfCheck's pipeline contract check (which calls `processDictation` directly with a fake
    /// processor) never triggers a real HUD panel. See PLAN.md step 8, Round 2/3 Codex findings.
    enum PostProcessingFallbackReason {
        case error(Error)
        case emptyOutput
    }

    /// Redacted diagnostic log for a post-processing fallback — provider label and HTTP status
    /// only, never a response body. Shared by both silent-fallback sites. See PLAN.md step 8,
    /// Round 2 Codex finding 5.
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

    /// Logs + shows the non-blocking HUD notice for a post-processing fallback. Used by
    /// `reprocess`, which (unlike `runPipeline`) has no separate "posted vs. not posted" HUD
    /// state to preserve. See PLAN.md step 8.
    private func reportPostProcessingFallback(_ reason: PostProcessingFallbackReason) {
        logPostProcessingFallback(reason)
        hud.flash("Cloud post-processing failed — used raw transcript (check API key/model in Settings)")
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
        forcedLanguage: String? = nil,
        // Raw path (CONTEXT.md/PLAN.md step 11): skips the Post-Processor entirely — refined IS
        // the transcript verbatim — and records the reserved "Raw Transcript" Library row name.
        skipPostProcessing: Bool = false,
        processor: (any PostProcessor)? = nil,
        insert: (String, InsertionTarget?) -> Bool = { Insertion.insert($0, target: $1) },
        // ponytail: closure default (not a protocol/factory) keeps SelfCheck hermetic to a temp
        // DB instead of writing test rows into the user's real Library on every run.
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
            // Raw path: the Post-Processor is never invoked — the Library row records the
            // reserved sentinel name instead of the resolved Template's, so raw rows are
            // distinguishable from ordinary post-processing-fallback rows (which keep their real
            // template name). See PLAN.md step 11.
            refined = transcription.text
            recordedTemplateName = TemplateStore.rawTranscriptTemplateName
        } else {
            let activeProcessor: any PostProcessor = processor ?? resolveActiveProcessor()
            do {
                let processed = try await activeProcessor.process(transcript: transcription.text, template: template, appName: appName)
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
                // Never lose the user's words — fall back to the raw transcript. See PLAN.md step 4.
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
        // Re-check the source row still exists immediately before persisting — a Delete
        // (single-row or Delete All) may have removed it while the LLM call above was in
        // flight. The result is still inserted at the cursor (already happened above); only the
        // Library write is skipped, so a derived row never points at a source the user just
        // deleted. `nil` (database unavailable) is not treated as "deleted" — the record() call
        // below still runs and surfaces its own error the normal way. See PLAN.md step 5.
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
        // A Library-save failure above takes priority (a data-loss-adjacent error the user must
        // see right now) — the fallback notice is only reported once the record succeeded, so it
        // can't be silently overwritten by "Library save failed". See PLAN.md step 8.
        if let fallbackReason {
            reportPostProcessingFallback(fallbackReason)
        }
    }

    /// Outcome of `redoLast()`'s guard + Library lookup — pure so SelfCheck can drive the full
    /// truth table (active/idle, DB error, empty Library, happy path) without a real
    /// HotKeyManager, Database, or Insertion side effect. See PLAN.md step 10.
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

    /// Fires from `HotKeyManager.onRedoKeyDown` (Redo Last hotkey, CONTEXT.md "Redo Last"):
    /// re-inserts the newest Library entry's Refined Output at the cursor. Never records or
    /// re-processes — same permissive (no target) insert path `reprocess` uses above.
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
