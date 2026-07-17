import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI

/// The Dictation Language Set, language pin, and per-app language rules snapshotted TOGETHER at
/// Recording start and held immutable for that Recording's duration — see
/// `AppCoordinator.captureRecordingLanguageSnapshot`. Value types make the freeze inherent: once
/// captured, no later mutation of the live `AppSettings` singleton can reach these fields. Used
/// at stop time so `resolveLanguage` is never handed a pin/rule value the user changed mid-
/// Recording, matching the Dictation Language Set's own existing start-snapshot semantics. See
/// Codex finding: stop-time live language-pin/appLanguageRules read.
struct RecordingLanguageSnapshot: Equatable {
    let candidateLanguages: [String]
    let pin: String
    let appLanguageRules: [String: String]
}

@MainActor
final class AppCoordinator: ObservableObject {
    enum CaptureOwner: Equatable {
        case none, dictation, voiceEdit
        var requiresDurableJournal: Bool { self == .dictation }
    }
    enum CaptureDecision: Equatable {
        case start, stop, busy(CaptureOwner)
        var allowsStart: Bool { self == .start }
    }
    enum TranslationRecoveryHUDOwner: Equatable { case none, recovery, recording }
    enum RecordingHUDEarlyTerminal: CaseIterable {
        case voiceEditEscape
        case externalDeadAudio
        case scratchpadDeadAudio
    }
    struct CaptureStopSettingsSnapshot: Equatable {
        let oneShotLanguage: String?
        let outputLanguage: OutputLanguage
        let cloudSnapshot: CloudLLMSettingsSnapshot
    }

    nonisolated static func captureStopSettingsSnapshot(
        oneShotLanguage: String?,
        selectedOutput: OutputLanguage?,
        defaultOutput: OutputLanguage,
        cloudSnapshot: CloudLLMSettingsSnapshot
    ) -> CaptureStopSettingsSnapshot {
        CaptureStopSettingsSnapshot(
            oneShotLanguage: oneShotLanguage,
            outputLanguage: selectedOutput ?? defaultOutput,
            cloudSnapshot: cloudSnapshot
        )
    }

    nonisolated static func captureStartDecision(current: CaptureOwner, requested: CaptureOwner) -> CaptureDecision {
        current == .none ? .start : .busy(current)
    }

    nonisolated static func captureStartDecision(
        current: CaptureOwner,
        requested: CaptureOwner,
        admissionState: CaptureAdmissionState
    ) -> CaptureDecision {
        guard !admissionState.isActive else {
            return .busy(current == .none ? .dictation : current)
        }
        return captureStartDecision(current: current, requested: requested)
    }

    nonisolated static func shouldHandleJournalFailure(
        callbackCaptureID: UUID,
        currentCaptureID: UUID?,
        alreadyHandled: Bool
    ) -> Bool {
        !alreadyHandled && callbackCaptureID == currentCaptureID
    }

    nonisolated static func capturePressDecision(current: CaptureOwner, pressed: CaptureOwner) -> CaptureDecision {
        if current == pressed { return .stop }
        return captureStartDecision(current: current, requested: pressed)
    }

    nonisolated static func voiceEditRecordingHUDText(captureWarnings: [String]) -> String {
        (["Speak the edit instruction, then press Voice Edit again"] + captureWarnings).joined(separator: "\n")
    }

    /// Returns a user-facing issue for buffers that contain no credible microphone signal.
    /// Normalized Float audio routinely has quiet speech well above 1e-7; keeping this gate at
    /// the numerical-noise floor rejects dead all-zero taps without treating silence between
    /// spoken words as a failed recording.
    nonisolated static func capturedAudioIssue(sampleCount: Int, peak: Float, rms: Float) -> String? {
        let deadSignalFloor: Float = 1e-7
        guard sampleCount > 0,
              peak.isFinite, rms.isFinite,
              peak >= 0, rms >= 0,
              peak > deadSignalFloor || rms > deadSignalFloor else {
            return "Recording failed — no microphone audio was captured"
        }
        return nil
    }

    static let shared = AppCoordinator()

    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var lastError: String?
    @Published private(set) var recoveryReconciliationReport: RecoveryReconciliationReport?
    @Published private(set) var recoveryHealth: RecoveryHealth = .initializing
    private var pendingOutputTranslationFailuresStorage: [OutputTranslationFailure] = []
    private lazy var translationRecoveryController = makeTranslationRecoveryController()
    weak var translationRecoveryPresentationRouter: (any TranslationRecoveryPresentationRouting)?
    private(set) var translationRecoveryHUDOwner: TranslationRecoveryHUDOwner = .none
    private var recordingHUDOwnershipGeneration: UUID?
    /// Set while the global hotkey listener couldn't be started (missing Accessibility
    /// permission) and we're waiting for the user to grant it. See Round 1 Codex finding 8.
    @Published private(set) var hotKeyStatusText: String?
    @Published private(set) var isHotKeyListening = false
    /// Health of the most recently completed microphone capture (PLAN.md F2.1) — `.unknown`
    /// until a capture has actually run, set from `AudioCapture.signalDiagnostics()` at capture
    /// stop (see `stopAndTranscribe`). Never conflated with Microphone's TCC authorization.
    @Published private(set) var microphoneCaptureHealth: MicrophoneCaptureHealth = .unknown
    /// Coordinator-owned Permission Diagnosis snapshot (PLAN.md F2, CONTEXT.md). Recomputed on
    /// demand via `refreshPermissionDiagnosis()` — never polled.
    @Published private(set) var permissionDiagnosis = PermissionDiagnosis()

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
    /// The configured Dictation Language Set, snapshotted at the start of the current capture
    /// (both `beginCapture` and `beginVoiceEditInstructionRecording` — the two capture-start
    /// paths) and held immutable for its duration, per "Settings that affect capture take effect
    /// at the start of the next Recording, never mid-Recording" (CONTEXT.md). Used to validate
    /// the pin/app-rule/one-shot language resolution (`resolveLanguage`) and as the local
    /// WhisperKit candidate set for every transcription request this capture makes. See PLAN.md
    /// F5.3/F5.4. Defaults to the live set so a coordinator-level call made before any capture
    /// starts still has a sane value.
    private var recordingLanguageSnapshot: [String] = AppSettings.shared.dictationLanguages
    /// The language pin and per-app language rules, snapshotted alongside
    /// `recordingLanguageSnapshot` at the same two capture-start sites — see
    /// `RecordingLanguageSnapshot`'s doc comment and `captureRecordingLanguageSnapshot`.
    private var recordingPinSnapshot: String = AppSettings.shared.languagePin
    private var recordingAppLanguageRulesSnapshot: [String: String] = AppSettings.shared.appLanguageRules
    @Published private(set) var recordingOutputSelection = RecordingOutputSelection()

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
    private let destinationLifecycle = RecordingDestinationLifecycle()
    private var recordingDestination: RecordingDestination? {
        get { destinationLifecycle.currentDestination }
        set {
            if let newValue { destinationLifecycle.install(newValue) }
            else { _ = destinationLifecycle.take() }
        }
    }
    weak var scratchpadRecordingRouter: (any ScratchpadRecordingRouting)? {
        get { destinationLifecycle.router }
        set { destinationLifecycle.router = newValue }
    }

    private let hotKeyManager = HotKeyManager()
    /// The `InsertionTarget` snapshotted at the most recent non-FreeTalker app activation
    /// (`NSWorkspace.didActivateApplicationNotification`) — the Dictation History Quick Panel's
    /// menu-item fallback path uses this, since by the time the menu item is clicked FreeTalker
    /// itself is already frontmost. See PLAN.md F3.2.
    private var lastNonSelfFrontmostTarget: InsertionTarget?
    private let audioCapture = AudioCapture()
    private var captureAdmission = CaptureAdmissionReducer()
    private var activeCaptureJournal: ActiveCaptureJournal?
    private var journalFinalizationTask: Task<Void, Never>?
    private var journalFailureHandled = false
    private struct PendingStopRequest {
        let destination: RecordingDestination
        let snapshot: (app: NSRunningApplication?, target: InsertionTarget?, contextTarget: ContextTargetSnapshot)?
        let skipPostProcessing: Bool
        let oneShotLanguage: String?
        let outputLanguage: OutputLanguage
        let cloudSnapshot: CloudLLMSettingsSnapshot
    }
    private var pendingStopRequest: PendingStopRequest?
    private struct PendingCaptureCleanup {
        enum Completion {
            case cancellation
            case startFailure(String)
        }
        let active: ActiveCaptureJournal
        let service: CaptureJournalService
        let destination: RecordingDestination
        let completion: Completion
    }
    private var pendingCaptureCleanup: PendingCaptureCleanup?
    private var cleanupRetryGate = CaptureCleanupRetryGate()
    private var cleanupRetryTask: Task<Void, Never>?
    private struct PendingFailurePreservation {
        let active: ActiveCaptureJournal
        let service: CaptureJournalService
        let message: String
    }
    private var pendingFailurePreservation: PendingFailurePreservation?
    private let hud = HUDController()
    private var recoveryStore: TranscriptionJobStore?
    private var recoveryStoreInitializationError: String?
    @Published private(set) var jobLibraryStore: JobLibraryStore?
    private var recoveryAdmissionStorageHealthy = false
    private var recoveryRunner: LocalJobRunner?
    private let recoveryLaunchGate = RecoveryLaunchGate()
    private var recoverySetupRetryScheduler = RecoverySetupRetryScheduler()
    @Published private(set) var recoverySetupRetryInFlight = false
    private var mediaImportRunner: LocalJobRunner?
    private var recoveryRetentionTask: Task<Void, Never>?
    private let localJobExecutionAuthority = LocalJobExecutionAuthority()
    private var cancellables = Set<AnyCancellable>()
    private var permissionPollTimer: Timer?

    private static let logger = Logger(subsystem: "org.freetalker.app", category: "capture")

    @discardableResult
    private func reduceCaptureAdmission(
        _ event: CaptureAdmissionEvent
    ) -> CaptureAdmissionAction {
        let action = captureAdmission.reduce(event)
        hotKeyManager.isCaptureLifecycleActive = captureAdmission.state.isActive
        return action
    }

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
        let recoveryStore: TranscriptionJobStore?
        do {
            recoveryStore = try Self.makeRecoveryStore()
            recoveryStoreInitializationError = nil
        } catch {
            recoveryStore = nil
            recoveryStoreInitializationError = error.localizedDescription
        }
        self.recoveryStore = recoveryStore
        do {
            snippetStore = try Self.makeSnippetStore()
            snippetStoreInitializationError = nil
        } catch {
            snippetStore = nil
            snippetStoreInitializationError = Self.snippetStoreErrorMessage(error)
        }
        jobLibraryStore = recoveryStore.map { JobLibraryStore(store: $0, recoveryDirectory: Self.recoveryDirectory) }
        if let recoveryStoreInitializationError {
            recoveryHealth = .unavailable(recoveryStoreInitializationError)
        }
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
        AppSettings.shared.$insertLastDictationHotKeySpec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotKeyListening() }
            .store(in: &cancellables)
        AppSettings.shared.$voiceEditHotKeySpec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotKeyListening() }
            .store(in: &cancellables)
        AppSettings.shared.$historyPanelHotKeySpec
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartHotKeyListening() }
            .store(in: &cancellables)
        // Tracks the last non-FreeTalker frontmost app for the Dictation History Quick Panel's
        // menu-item fallback (PLAN.md F3.2) — never removed, same lifetime as this singleton.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in self?.lastNonSelfFrontmostTarget = Insertion.snapshotTarget(app: app) }
        }
        AppSettings.shared.$dictationLanguages
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSet in self?.handleDictationLanguagesChange(newSet) }
            .store(in: &cancellables)
        AppSettings.shared.$mediaImportRetention
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] retention in
                Task { @MainActor in
                    guard let self else { return }
                    await Self.routeMediaImportRetentionChange(retention) { [weak self] value in
                        await self?.purgeMediaImports(retention: value)
                    }
                }
            }
            .store(in: &cancellables)
        AppSettings.shared.$recoveryRetention
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] retention in
                self?.scheduleRecoveryRetentionPurge(retention)
            }
            .store(in: &cancellables)
        Publishers.CombineLatest4(
            AppSettings.shared.$defaultOutputLanguage,
            AppSettings.shared.$llmProvider,
            AppSettings.shared.$cloudLLMBaseURL,
            AppSettings.shared.$cloudLLMModel
        )
        .dropFirst()
        .map { _ in () }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            DispatchQueue.main.async { self?.updateRecordingPanel() }
        }
        .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .cloudLLMCredentialsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRecordingPanel() }
            .store(in: &cancellables)
        // Cheap catch-all: the user activating the app (opening Settings, the Library, even
        // just the menu bar popover focusing a window) re-checks the tap — catching
        // permissions granted in System Settings while the app was already running.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Self.recoverHotKeyListeningIfNeeded(isListening: self.hotKeyManager.isListening) {
                    self.ensureHotKeyListening()
                }
                // App activation is one of Permission Diagnosis's explicit recompute triggers
                // (PLAN.md F2.3) — catches permissions granted/revoked in System Settings while
                // this app was backgrounded.
                self.refreshPermissionDiagnosis()
            }
        }
        // Amendment B3: clicking the HUD pill locks an in-progress PTT recording or stops a
        // locked one — wired once, not per-`ensureHotKeyListening()` call.
        hud.onPillClick = { [weak self] in self?.handlePillClick() }
        hud.onPanelCancel = { [weak self] in self?.handlePanelCancel() }
        hud.onPanelDone = { [weak self] in self?.handlePanelDone() }
        hud.onPanelRaw = { [weak self] in self?.handlePanelRaw() }
        hud.onPanelLanguage = { [weak self] code in self?.handlePanelOneShotLanguage(code) }
        hud.onPanelOutput = { [weak self] language in self?.selectRecordingOutput(language) }
        hud.onPanelCycleTemplate = { [weak self] in self?.handlePanelCycleTemplate() }
        hud.onPanelLock = { [weak self] in self?.handlePillClick() }
        hud.onRetryTranslation = { [weak self] in self?.retryNextTranslation() }
        hud.onInsertSourceText = { [weak self] in self?.insertNextTranslationSource() }
        // Seeds an initial Permission Diagnosis snapshot; `ensureHotKeyListening()` (called by
        // App.swift right after construction) settles `isHotKeyListening` before the menu bar or
        // Privacy tab can first observe it.
        refreshPermissionDiagnosis()
    }

    func selectRecordingOutput(_ language: OutputLanguage) {
        recordingOutputSelection.select(language, isRecording: isRecording)
        updateRecordingPanel()
    }

    var presentedTranslationState: TranslationControlsState {
        let settings = AppSettings.shared
        let snapshot = settings.cloudLLMSnapshot
        return Self.translationControlsState(
            defaultOutput: settings.defaultOutputLanguage,
            selection: recordingOutputSelection,
            snapshot: snapshot
        )
    }

    nonisolated static func translationControlsState(
        defaultOutput: OutputLanguage,
        selection: RecordingOutputSelection,
        snapshot: CloudLLMSettingsSnapshot
    ) -> TranslationControlsState {
        TranslationControlsState(
            effectiveOutput: selection.effective ?? defaultOutput,
            override: selection.effective,
            availability: .make(eligibility: snapshot.eligibility, provider: snapshot.provider)
        )
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
            isHotKeyListening = true
            hotKeyStatusText = nil
            stopHotKeyRetryPoll()
            return
        }
        hotKeyManager.onKeyDown = { [weak self] eventSeconds in self?.handleKeyDown(eventSeconds: eventSeconds) }
        hotKeyManager.onKeyUp = { [weak self] eventSeconds in self?.handleKeyUp(eventSeconds: eventSeconds) }
        hotKeyManager.onEscape = { [weak self] in self?.handleEscape() }
        hotKeyManager.onInsertLastDictationKeyDown = { [weak self] _ in self?.insertLastDictation() }
        Self.configureVoiceEditHotKey(manager: hotKeyManager) { [weak self] in
            self?.handleVoiceEditHotKey()
        }
        hotKeyManager.onHistoryPanelKeyDown = { [weak self] _, target in
            self?.handleHistoryPanelHotKey(target: target)
        }
        if hotKeyManager.start(
            spec: AppSettings.shared.hotKeySpec,
            insertLastDictationSpec: AppSettings.shared.insertLastDictationHotKeySpec,
            voiceEditSpec: AppSettings.shared.voiceEditHotKeySpec,
            historyPanelSpec: AppSettings.shared.historyPanelHotKeySpec
        ) {
            isHotKeyListening = true
            hotKeyStatusText = nil
            stopHotKeyRetryPoll()
        } else {
            isHotKeyListening = false
            updateHotKeyStatusText()
            beginHotKeyRetryPollIfNeeded()
        }
    }

    nonisolated static func recoverHotKeyListeningIfNeeded(
        isListening: Bool,
        recover: () -> Void
    ) {
        guard !isListening else { return }
        recover()
    }

    static func configureVoiceEditHotKey(manager: HotKeyManager, handler: @escaping @MainActor () -> Void) {
        manager.onVoiceEditKeyDown = { _ in handler() }
    }

    private func handleVoiceEditHotKey() {
        let decision = captureAdmission.state.isActive
            ? Self.captureStartDecision(
                current: captureOwner, requested: .voiceEdit,
                admissionState: captureAdmission.state
            )
            : Self.capturePressDecision(current: captureOwner, pressed: .voiceEdit)
        switch decision {
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
        guard !recoverySetupRetryInFlight else {
            hud.flash("Recovery setup is in progress — try Voice Edit again shortly")
            pendingVoiceEditSelection = nil
            return
        }
        guard Self.captureStartDecision(
            current: captureOwner, requested: .voiceEdit,
            admissionState: captureAdmission.state
        ) == .start,
              !isProcessing else {
            hud.flash("Finish the current recording first")
            pendingVoiceEditSelection = nil
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.flash("Microphone not authorized — check System Settings")
            pendingVoiceEditSelection = nil
            refreshPermissionDiagnosis()
            return
        }
        do {
            try audioCapture.start(
                deviceUID: AppSettings.shared.microphoneDeviceUID,
                noiseSuppression: AppSettings.shared.noiseSuppressionEnabled
            )
            let languageSnapshot = Self.captureRecordingLanguageSnapshot(from: AppSettings.shared)
            recordingLanguageSnapshot = languageSnapshot.candidateLanguages
            recordingPinSnapshot = languageSnapshot.pin
            recordingAppLanguageRulesSnapshot = languageSnapshot.appLanguageRules
            captureOwner = .voiceEdit
            isRecording = true
            hotKeyManager.isRecording = true
            recordingHUDWillPresent()
            hud.show(text: Self.voiceEditRecordingHUDText(captureWarnings: audioCapture.captureWarnings))
        } catch {
            pendingVoiceEditSelection = nil
            let message = Self.captureStartFailureMessage(errorDescription: error.localizedDescription)
            lastError = message
            hud.flash(message)
        }
    }

    private func finishVoiceEditInstructionRecording() {
        let selection = pendingVoiceEditSelection
        pendingVoiceEditSelection = nil
        captureOwner = .none
        isRecording = false
        hotKeyManager.isRecording = false
        let samples = audioCapture.stop()
        let (peak, rms) = AudioLevel.peakAndRMS(samples)
        if let issue = Self.capturedAudioIssue(sampleCount: samples.count, peak: peak, rms: rms) {
            hud.flash(issue)
            recordingHUDDidReachTerminalState()
            return
        }
        guard let selection else {
            hud.flash("No voice instruction captured")
            recordingHUDDidReachTerminalState()
            return
        }
        isProcessing = true
        let hudGeneration = recordingHUDWillPresent()
        hud.show(text: "Transcribing instruction locally…")
        Task {
            defer {
                isProcessing = false
                recordingHUDDidReachTerminalState(generation: hudGeneration)
            }
            do {
                // Voice Edit is deliberately pinned to the on-device engine even when normal
                // dictation is configured for cloud STT.
                let transcription = try await whisperEngine.transcribe(samples: samples, forcedLanguage: nil, candidateLanguages: recordingLanguageSnapshot)
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
        isHotKeyListening = false
        ensureHotKeyListening()
    }

    /// Recomputes `permissionDiagnosis` from current TCC/AX/IOHID claims plus the tap's actual
    /// operational status (PLAN.md F2.1/F2.3). Deliberately on-demand only — call sites are:
    /// app activation, menu-bar menu open, the Privacy tab's "Run Diagnosis" button, and
    /// permission-class insertion/capture failures. Never polled.
    func refreshPermissionDiagnosis() {
        let settings = AppSettings.shared
        let inputMonitoringRequired = PermissionDiagnosis.anyHotKeyBound(
            pttSpec: settings.hotKeySpec,
            insertLastDictationSpec: settings.insertLastDictationHotKeySpec,
            voiceEditSpec: settings.voiceEditHotKeySpec,
            historyPanelSpec: settings.historyPanelHotKeySpec
        )
        let inputMonitoringRawAuthorized = Permissions.isInputMonitoringAuthorized()
        permissionDiagnosis = PermissionDiagnosis(
            accessibility: PermissionDiagnosis.accessibilityState(
                rawTrusted: Permissions.isAccessibilityTrusted(),
                hotKeyOperational: isHotKeyListening,
                inputMonitoringRawAuthorized: inputMonitoringRawAuthorized
            ),
            microphone: PermissionDiagnosis.microphoneAuthorizationState(
                AVCaptureDevice.authorizationStatus(for: .audio)
            ),
            microphoneCaptureHealth: microphoneCaptureHealth,
            inputMonitoring: PermissionDiagnosis.inputMonitoringState(
                rawAuthorized: inputMonitoringRawAuthorized,
                hotKeyOperational: isHotKeyListening
            ),
            inputMonitoringRequired: inputMonitoringRequired
        )
    }

    nonisolated static func captureStartFailureMessage(errorDescription: String) -> String {
        "Could not start recording: \(errorDescription)"
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

    nonisolated static func launcherStartDecision(isRecording: Bool, isProcessing: Bool) -> Bool {
        !isRecording && !isProcessing
    }

    nonisolated static func externalStopSnapshot<Value>(
        for destination: RecordingDestination,
        capture: () -> Value
    ) -> Value? {
        guard destination == .external else { return nil }
        return capture()
    }

    func pendingScratchpadRecording(for token: ScratchpadInsertionToken) -> String? {
        destinationLifecycle.pending(for: token)
    }

    func consumePendingScratchpadRecording(for token: ScratchpadInsertionToken) -> String? {
        destinationLifecycle.consumePending(for: token)
    }

    func pendingScratchpadRecordings() -> [RecordingDestinationLifecycle.PendingRecording] {
        destinationLifecycle.pendingRecordings()
    }

    func consumePendingScratchpadFailure() -> String? {
        destinationLifecycle.consumePendingFailure()
    }

    func storePendingScratchpadRecording(_ text: String, for token: ScratchpadInsertionToken) {
        destinationLifecycle.storePending(text, for: token)
    }

    func clearPendingScratchpadRecording(for token: ScratchpadInsertionToken) {
        destinationLifecycle.clearPending(for: token)
    }

    func enqueueOutputTranslationFailure(_ failure: OutputTranslationFailure) {
        pendingOutputTranslationFailuresStorage.append(failure)
    }

    @discardableResult
    func handleOutputTranslationFailure(_ failure: OutputTranslationFailure) -> String {
        handleOutputTranslationFailure(failure, externalTarget: nil)
    }

    func handleOutputTranslationFailure(
        _ failure: OutputTranslationFailure,
        externalTarget: InsertionTarget?
    ) -> String {
        enqueueOutputTranslationFailure(failure)
        translationRecoveryController.enqueue(failure, externalTarget: externalTarget)
        return failure.localizedDescription
    }

    var nextTranslationRecoveryPresentation: TranslationRecoveryPresentation? {
        translationRecoveryController.nextPresentation
    }

    private func makeTranslationRecoveryController(
        snapshot: @escaping PendingTranslationRecoveryController.Snapshot = { AppSettings.shared.cloudLLMSnapshot },
        translate: @escaping PendingTranslationRecoveryController.Translate = { source, template, policy, snapshot in
            try await TranslationService().process(
                source: source, template: template, policy: policy, snapshot: snapshot
            )
        },
        deliver: PendingTranslationRecoveryController.Deliver? = nil,
        recordResolved: PendingTranslationRecoveryController.RecordResolved? = nil
    ) -> PendingTranslationRecoveryController {
        PendingTranslationRecoveryController(
            snapshot: snapshot,
            translate: translate,
            deliver: deliver ?? { [weak self] text, destination, externalTarget in
                guard let self else { return false }
                switch destination {
                case .external:
                    let outcome = Insertion.insert(text, target: externalTarget)
                    if outcome.isPermissionClassFailure { self.refreshPermissionDiagnosis() }
                    return outcome.posted
                case .scratchpad(let token):
                    return self.scratchpadRecordingRouter?.completeTranslationRecovery(text, for: token) ?? false
                }
            },
            recordResolved: recordResolved ?? { record in
                try LibraryStore.shared.record(
                    language: record.sourceLanguage.rawValue,
                    requestedOutputLanguage: record.requestedOutputLanguage,
                    template: record.templateName,
                    transcript: record.rawTranscript,
                    refined: record.finalOutput,
                    engine: record.engineName,
                    bundleID: record.bundleID
                )
            },
            onHistoryFailure: { [weak self] message in self?.hud.flash(message) },
            onChange: { [weak self] in self?.presentTranslationRecoveryState() }
        )
    }

    func configureTranslationRecoveryForTesting(
        snapshot: @escaping PendingTranslationRecoveryController.Snapshot,
        translate: @escaping PendingTranslationRecoveryController.Translate,
        deliver: @escaping PendingTranslationRecoveryController.Deliver,
        recordResolved: @escaping PendingTranslationRecoveryController.RecordResolved = { _ in }
    ) {
        translationRecoveryController = makeTranslationRecoveryController(
            snapshot: snapshot, translate: translate, deliver: deliver,
            recordResolved: recordResolved
        )
        presentTranslationRecoveryState()
    }

    func resetTranslationRecoveryTestingConfiguration() {
        translationRecoveryController = makeTranslationRecoveryController()
        presentTranslationRecoveryState()
    }

    func retryNextTranslation() {
        guard let id = translationRecoveryController.nextID else { return }
        Task { [weak self] in
            guard let self else { return }
            await translationRecoveryController.retryTranslation(id: id)
            resolveTranslationFailureStorageIfNeeded(id: id)
        }
    }

    func insertNextTranslationSource() {
        guard let id = translationRecoveryController.nextID else { return }
        translationRecoveryController.insertSourceText(id: id)
        resolveTranslationFailureStorageIfNeeded(id: id)
    }

    private func resolveTranslationFailureStorageIfNeeded(id: UUID) {
        if !translationRecoveryController.pendingRecoveries.contains(where: { $0.failureID == id }) {
            if let index = pendingOutputTranslationFailuresStorage.firstIndex(where: { $0.id == id }) {
                pendingOutputTranslationFailuresStorage.remove(at: index)
            }
        }
        presentTranslationRecoveryState()
    }

    private func presentTranslationRecoveryState() {
        defer { translationRecoveryPresentationRouter?.translationRecoveryPresentationDidChange() }
        guard translationRecoveryHUDOwner != .recording else { return }
        if let presentation = translationRecoveryController.nextPresentation {
            translationRecoveryHUDOwner = .recovery
            hud.showTranslationRecovery(presentation)
        } else if translationRecoveryHUDOwner == .recovery {
            translationRecoveryHUDOwner = .none
            hud.hide()
        }
    }

    @discardableResult
    func recordingHUDWillPresent() -> UUID {
        let generation = UUID()
        recordingHUDOwnershipGeneration = generation
        translationRecoveryHUDOwner = .recording
        return generation
    }

    func recordingHUDDidReachTerminalState(generation: UUID? = nil) {
        guard translationRecoveryHUDOwner == .recording else { return }
        if let generation, generation != recordingHUDOwnershipGeneration { return }
        recordingHUDOwnershipGeneration = nil
        translationRecoveryHUDOwner = .none
        presentTranslationRecoveryState()
        runDeferredRecoverySetupRetryIfPossible()
    }

    func recordingHUDDidEndEarly(
        _ terminal: RecordingHUDEarlyTerminal,
        generation: UUID? = nil
    ) {
        switch terminal {
        case .voiceEditEscape, .externalDeadAudio, .scratchpadDeadAudio:
            recordingHUDDidReachTerminalState(generation: generation)
        }
    }

    func pendingOutputTranslationFailures() -> [OutputTranslationFailure] {
        pendingOutputTranslationFailuresStorage
    }

    func consumePendingOutputTranslationFailure(id: UUID) -> OutputTranslationFailure? {
        guard let index = pendingOutputTranslationFailuresStorage.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        translationRecoveryController.discard(id: id)
        return pendingOutputTranslationFailuresStorage.remove(at: index)
    }

    func consumeNextPendingOutputTranslationFailure() -> OutputTranslationFailure? {
        guard !pendingOutputTranslationFailuresStorage.isEmpty else { return nil }
        let failure = pendingOutputTranslationFailuresStorage.removeFirst()
        translationRecoveryController.discard(id: failure.id)
        return failure
    }

    @discardableResult
    func deliverScratchpadCompletion(_ text: String, for token: ScratchpadInsertionToken) -> Bool {
        (try? destinationLifecycle.complete(text, destination: .scratchpad(token)) {}) ?? false
    }

    static func routeDestinationEvent(
        _ event: RecordingDestinationEvent,
        destination: RecordingDestination,
        router: (any ScratchpadRecordingRouting)?,
        externalCompletion: () throws -> Void
    ) throws -> Bool {
        switch destination {
        case .external:
            if case .completion = event { try externalCompletion() }
            return true
        case .scratchpad(let token):
            guard let router else { return false }
            switch event {
            case .preview(let text): router.updatePreview(text, for: token)
            case .completion(let text): return router.completeRecording(text, for: token)
            case .cancellation: router.cancelRecording(for: token)
            case .failure(let message): router.failRecording(message, for: token)
            }
            return true
        }
    }

    @discardableResult
    func startHandsFreeRecording(destination: RecordingDestination = .external) -> Bool {
        guard Self.launcherStartDecision(isRecording: isRecording, isProcessing: isProcessing),
              beginCapture(destination: destination) else { return false }
        recordingState = .locked(ignoreNextKeyUp: false)
        enterLockedMode()
        return true
    }

    func stopCurrentRecording() {
        guard recordingState != .idle else { return }
        recordingState = .idle
        stopAndTranscribe()
    }

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
            if beginCapture(destination: .external) {
                recordingState = newState
                updateRecordingPanel()
            }
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
        let snapshot = Self.externalStopSnapshot(for: recordingDestination ?? .external) {
            let app = NSWorkspace.shared.frontmostApplication
            return (app: app, target: Insertion.snapshotTarget(app: app), contextTarget: snapshotContextTarget(app: app))
        }
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: .pillClick, currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .enterLocked:
            enterLockedMode()
        case .stopAndTranscribe:
            stopAndTranscribe(preSnapshotted: snapshot)
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
            recordingHUDDidEndEarly(.voiceEditEscape)
            return
        }
        if captureAdmission.state.isActive {
            recordingState = .idle
            cancelRecording()
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
        let snapshot = Self.externalStopSnapshot(for: recordingDestination ?? .external) {
            let app = NSWorkspace.shared.frontmostApplication
            return (app: app, target: Insertion.snapshotTarget(app: app), contextTarget: snapshotContextTarget(app: app))
        }
        let (newState, action) = RecordingStateMachine.transition(state: recordingState, event: Self.recordingEvent(for: skipPostProcessing ? .raw : .done), currentGeneration: recordingGeneration)
        recordingState = newState
        switch action {
        case .stopAndTranscribe:
            stopAndTranscribe(preSnapshotted: snapshot, skipPostProcessing: skipPostProcessing)
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

    /// Eager one-shot coercion (PLAN.md F5.4): the moment the configured Dictation Language Set
    /// changes, an active one-shot selection referencing a language no longer in it is cleared
    /// rather than surviving until the next stop-time read. A `nil`/still-valid current value is
    /// left untouched.
    nonisolated static func coercedOneShotLanguage(current: String?, allowed: [String]) -> String? {
        guard let current, !allowed.contains(current) else { return current }
        return nil
    }

    private func handleDictationLanguagesChange(_ newSet: [String]) {
        let coerced = Self.coercedOneShotLanguage(current: oneShotLanguage, allowed: newSet)
        guard coerced != oneShotLanguage else { return }
        oneShotLanguage = coerced
        guard recordingState != .idle else { return }
        updateRecordingPanel()
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
    private func beginCapture(destination: RecordingDestination) -> Bool {
        if pendingFailurePreservation != nil {
            retryPendingFailurePreservation()
            return false
        }
        if pendingCaptureCleanup != nil {
            retryPendingCaptureCleanup()
            return false
        }
        guard Self.captureStartDecision(
            current: captureOwner, requested: .dictation,
            admissionState: captureAdmission.state
        ) == .start else {
            return false
        }
        guard recoveryHealth.allowsCapture(
            requiresDurableJournal: destination.requiresDurableJournal,
            admissionStorageHealthy: recoveryAdmissionStorageHealthy
        ) else {
            let detail = recoveryHealth.message ?? "Recovery storage is not ready."
            let message = "Recording unavailable: \(detail)"
            destinationLifecycle.failStart(destination, message: message)
            recordingOutputSelection.resolveTerminal()
            lastError = message
            hud.flash(message)
            return false
        }
        recordingDestination = nil
        oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear)
        let languageSnapshot = Self.captureRecordingLanguageSnapshot(from: AppSettings.shared)
        recordingLanguageSnapshot = languageSnapshot.candidateLanguages
        recordingPinSnapshot = languageSnapshot.pin
        recordingAppLanguageRulesSnapshot = languageSnapshot.appLanguageRules
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.logger.log("key down: micAuthorizationStatus=\(micStatus.rawValue, privacy: .public)")
        // Guard unconditionally rather than proceeding to record silence — a denied/stale TCC
        // grant lets AVAudioEngine start and "succeed" while delivering only zeros, which is
        // exactly what produces Whisper's silent-audio hallucination ("Thank you" for real
        // speech). See live-mic silence investigation, root cause H1.
        guard micStatus == .authorized else {
            recordingOutputSelection.resolveTerminal()
            let message = "Microphone not authorized — check System Settings › Privacy & Security › Microphone"
            hud.flash(message)
            refreshPermissionDiagnosis()
            _ = destinationLifecycle.begin(destination, start: { false }, failureMessage: { message })
            return false
        }
        guard destination.requiresDurableJournal, let recoveryStore else {
            let message = "Could not prepare durable recording storage"
            destinationLifecycle.failStart(destination, message: message)
            recordingOutputSelection.resolveTerminal()
            lastError = message
            hud.flash(message)
            return false
        }

        destinationLifecycle.install(destination)
        _ = recordingOutputSelection.start(default: AppSettings.shared.defaultOutputLanguage)
        captureOwner = .dictation
        recordingGeneration += 1
        pendingStopRequest = nil
        journalFailureHandled = false
        let captureID = UUID()
        _ = reduceCaptureAdmission(.begin(
            captureID: captureID, destination: destination.journalIdentifier
        ))
        let request = CaptureStartRequest(
            id: captureID,
            directory: Self.recoveryDirectory.appendingPathComponent(
                captureID.uuidString, isDirectory: true
            ),
            capturedAt: Date(), sampleRate: 16_000, channelCount: 1,
            inputDeviceUID: AppSettings.shared.microphoneDeviceUID,
            destination: destination.journalIdentifier
        )
        let service = CaptureJournalService(
            fileSystem: LocalJournalFileSystem(), ledger: recoveryStore,
            recoveryRoot: Self.recoveryDirectory,
            onFailure: { [weak self] message in
                Task { @MainActor in
                    self?.handleJournalConsumerFailure(
                        captureID: captureID, result: .failed(message)
                    )
                }
            }
        )
        Task { [weak self] in
            do {
                let active = try await Task.detached {
                    try await service.prepare(request)
                }.value
                self?.completeCaptureAdmission(active, service: service)
            } catch let unresolved as UnresolvedCapturePreparationFailure {
                self?.retainUnresolvedPreparationFailure(
                    unresolved, destination: destination
                )
            } catch let owned as OwnedCapturePreparationFailure {
                self?.handleOwnedPreparationFailure(
                    owned, service: service, destination: destination
                )
            } catch {
                self?.failCaptureAdmission(
                    captureID: captureID,
                    destination: destination,
                    message: "Could not prepare recording storage: \(error.localizedDescription)"
                )
            }
        }
        return true
    }

    private func retainUnresolvedPreparationFailure(
        _ failure: UnresolvedCapturePreparationFailure,
        destination: RecordingDestination
    ) {
        guard reduceCaptureAdmission(.preparationOwnershipUnknown(
            captureID: failure.request.id, message: failure.message
        )) == .fail(failure.message) else { return }
        pendingStopRequest = nil
        recordingState = .idle
        recordingOutputSelection.resolveTerminal()
        destinationLifecycle.failStart(destination, message: failure.message)
        lastError = failure.message
        recoveryAdmissionStorageHealthy = false
        recoveryHealth = .unavailable(failure.message)
        hud.flash("Recording preparation needs recovery")
        recordingHUDDidReachTerminalState()
    }

    private func handleOwnedPreparationFailure(
        _ failure: OwnedCapturePreparationFailure,
        service: CaptureJournalService,
        destination: RecordingDestination
    ) {
        guard reduceCaptureAdmission(.prepared(
            captureID: failure.active.session.id
        )) != .none else { return }
        _ = reduceCaptureAdmission(.cancelRequested)
        pendingStopRequest = nil
        recordingState = .idle
        activeCaptureJournal = failure.active
        lastError = failure.message
        hud.flash("Recording preparation failed — cleanup retained")
        Task {
            do {
                try await service.cancelAndClean(failure.active)
                _ = reduceCaptureAdmission(.cleanupFinished(
                    captureID: failure.active.session.id
                ))
                activeCaptureJournal = nil
                captureOwner = .none
                pendingCaptureCleanup = nil
                destinationLifecycle.failStart(destination, message: failure.message)
                recordingOutputSelection.resolveTerminal()
                lastError = failure.message
                hud.flash("Recording preparation failed — recovery cleanup completed")
                recordingHUDDidReachTerminalState()
            } catch {
                retainFailedCleanup(
                    active: failure.active, service: service,
                    destination: destination,
                    completion: .startFailure(failure.message),
                    cleanupError: error
                )
            }
        }
    }

    private func completeCaptureAdmission(
        _ active: ActiveCaptureJournal,
        service: CaptureJournalService
    ) {
        let action = reduceCaptureAdmission(.prepared(captureID: active.session.id))
        switch action {
        case .cancel:
            Task { await cleanCancelledAdmission(active, service: service) }
        case .start, .startAndStop:
            do {
                try audioCapture.start(
                    deviceUID: AppSettings.shared.microphoneDeviceUID,
                    noiseSuppression: AppSettings.shared.noiseSuppressionEnabled,
                    captureID: active.session.id,
                    sampleConsumer: { active.writer.enqueue($0) },
                    onConsumerFailure: { [weak self] result in
                        Task { @MainActor in
                            self?.handleJournalConsumerFailure(
                                captureID: active.session.id, result: result
                            )
                        }
                    },
                    onSignalDecision: { [weak self] decision in
                        Task { @MainActor in
                            self?.handleMicrophoneSignalDecision(
                                decision, captureID: active.session.id
                            )
                        }
                    }
                )
                activeCaptureJournal = active
                startLivePreviewIfNeeded()
                if case .startAndStop = action {
                    let pending = pendingStopRequest
                    pendingStopRequest = nil
                    stopAndTranscribe(
                        stopRequest: pending
                    )
                }
            } catch {
                let message = Self.captureStartFailureMessage(
                    errorDescription: error.localizedDescription
                )
                _ = reduceCaptureAdmission(.cancelRequested)
                Task {
                    let destination = recordingDestination ?? .external
                    do {
                        try await service.cancelAndClean(active)
                        _ = reduceCaptureAdmission(.cleanupFinished(
                            captureID: active.session.id
                        ))
                        activeCaptureJournal = nil
                        captureOwner = .none
                        destinationLifecycle.failStart(destination, message: message)
                        recordingState = .idle
                        recordingOutputSelection.resolveTerminal()
                        lastError = message
                        hud.flash(message)
                        recordingHUDDidReachTerminalState()
                    } catch {
                        retainFailedCleanup(
                            active: active, service: service,
                            destination: destination,
                            completion: .startFailure(message),
                            cleanupError: error
                        )
                    }
                }
            }
        case .none, .finish, .preserveFailure, .fail:
            break
        }
    }

    private func failCaptureAdmission(
        captureID: UUID,
        destination: RecordingDestination,
        message: String
    ) {
        let cancellationRequested: Bool = if case .preparing(_, _, _, true) = captureAdmission.state {
            true
        } else {
            false
        }
        let action = reduceCaptureAdmission(.preparationFailed(
            captureID: captureID, message: message
        ))
        guard action != .none else { return }
        pendingStopRequest = nil
        recordingState = .idle
        captureOwner = .none
        recordingOutputSelection.resolveTerminal()
        if cancellationRequested {
            finishCancellationPresentation()
            return
        }
        destinationLifecycle.failStart(destination, message: message)
        lastError = message
        recoveryAdmissionStorageHealthy = false
        recoveryHealth = .unavailable(message)
        hud.flash(message)
        recordingHUDDidReachTerminalState()
    }

    private func cleanCancelledAdmission(
        _ active: ActiveCaptureJournal,
        service: CaptureJournalService
    ) async {
        do {
            try await service.cancelAndClean(active)
            _ = reduceCaptureAdmission(.cleanupFinished(captureID: active.session.id))
            activeCaptureJournal = nil
            captureOwner = .none
            pendingCaptureCleanup = nil
            pendingFailurePreservation = nil
            finishCancellationPresentation()
        } catch {
            retainFailedCleanup(
                active: active, service: service,
                destination: recordingDestination ?? .external,
                completion: .cancellation,
                cleanupError: error
            )
        }
    }

    private func retainFailedCleanup(
        active: ActiveCaptureJournal,
        service: CaptureJournalService,
        destination: RecordingDestination,
        completion: PendingCaptureCleanup.Completion,
        cleanupError: Error
    ) {
        let operation = switch completion {
        case .cancellation: "Recording cancellation"
        case .startFailure(let message): message
        }
        let detail = "\(operation) cleanup failed: \(cleanupError.localizedDescription)"
        guard reduceCaptureAdmission(.cleanupFailed(
            captureID: active.session.id, message: detail
        )) == .fail(detail) else { return }
        activeCaptureJournal = active
        pendingCaptureCleanup = PendingCaptureCleanup(
            active: active, service: service, destination: destination,
            completion: completion
        )
        pendingFailurePreservation = nil
        lastError = detail
        recoveryHealth = .degraded(detail)
        hud.flash("Recording cleanup needs retry — recovery retained")
    }

    private func retryPendingCaptureCleanup() {
        guard let pending = pendingCaptureCleanup else { return }
        let captureID = pending.active.session.id
        guard let generation = cleanupRetryGate.begin(captureID: captureID) else { return }
        cleanupRetryTask = Task {
            do {
                try await pending.service.resumeCleanup(
                    captureID: captureID
                )
                guard cleanupRetryGate.finish(
                    captureID: captureID, generation: generation
                ), pendingCaptureCleanup?.active.session.id == captureID,
                   case .cleanupFailed(let stateCaptureID, _) = captureAdmission.state,
                   stateCaptureID == captureID else { return }
                _ = reduceCaptureAdmission(.cleanupFinished(
                    captureID: captureID
                ))
                cleanupRetryTask = nil
                pendingCaptureCleanup = nil
                activeCaptureJournal = nil
                captureOwner = .none
                switch pending.completion {
                case .cancellation:
                    finishCancellationPresentation()
                case .startFailure(let message):
                    destinationLifecycle.failStart(
                        pending.destination, message: message
                    )
                    recordingOutputSelection.resolveTerminal()
                    hud.flash("Recording cleanup completed — try again")
                    recordingHUDDidReachTerminalState()
                }
            } catch {
                guard cleanupRetryGate.finish(
                    captureID: captureID, generation: generation
                ), pendingCaptureCleanup?.active.session.id == captureID,
                   case .cleanupFailed(let stateCaptureID, _) = captureAdmission.state,
                   stateCaptureID == captureID else { return }
                cleanupRetryTask = nil
                retainFailedCleanup(
                    active: pending.active, service: pending.service,
                    destination: pending.destination,
                    completion: pending.completion,
                    cleanupError: error
                )
            }
        }
    }

    private func retryPendingFailurePreservation() {
        guard let pending = pendingFailurePreservation else { return }
        let captureID = pending.active.session.id
        guard let generation = cleanupRetryGate.begin(captureID: captureID) else { return }
        cleanupRetryTask = Task {
            do {
                try await pending.service.preserveFailure(
                    pending.active, message: pending.message
                )
                guard cleanupRetryGate.finish(
                    captureID: captureID, generation: generation
                ), pendingFailurePreservation?.active.session.id == captureID,
                   case .cleanupFailed(let stateCaptureID, _) = captureAdmission.state,
                   stateCaptureID == captureID else { return }
                _ = reduceCaptureAdmission(.failureHandled(captureID: captureID))
                cleanupRetryTask = nil
                pendingFailurePreservation = nil
                activeCaptureJournal = nil
                captureOwner = .none
                let destination = destinationLifecycle.take()
                if case .scratchpad = destination {
                    _ = try? Self.routeDestinationEvent(
                        .failure(pending.message), destination: destination,
                        router: scratchpadRecordingRouter
                    ) {}
                }
                recordingOutputSelection.resolveTerminal()
                hud.flash("Recording retained for recovery — try again")
                recordingHUDDidReachTerminalState()
            } catch {
                guard cleanupRetryGate.finish(
                    captureID: captureID, generation: generation
                ), pendingFailurePreservation?.active.session.id == captureID,
                   case .cleanupFailed(let stateCaptureID, _) = captureAdmission.state,
                   stateCaptureID == captureID else { return }
                cleanupRetryTask = nil
                let detail = "\(pending.message): \(error.localizedDescription)"
                _ = reduceCaptureAdmission(.cleanupFailed(
                    captureID: captureID, message: detail
                ))
                lastError = detail
                hud.flash("Recovery ownership still needs retry")
            }
        }
    }

    private func finishCancellationPresentation() {
        destinationLifecycle.cancel {}
        pendingStopRequest = nil
        captureOwner = .none
        oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear)
        recordingOutputSelection.resolveTerminal()
        hud.flash("Cancelled")
        recordingHUDDidReachTerminalState()
    }

    private func handleJournalConsumerFailure(
        captureID: UUID,
        result: CaptureJournalWriter.EnqueueResult
    ) {
        guard AudioCapture.consumerFailureAction(for: result) == .escalate else { return }
        guard Self.shouldHandleJournalFailure(
            callbackCaptureID: captureID,
            currentCaptureID: captureAdmission.state.captureID,
            alreadyHandled: journalFailureHandled
        ) else { return }
        guard let active = activeCaptureJournal, let recoveryStore else { return }
        guard active.session.id == captureID else { return }
        journalFailureHandled = true
        guard reduceCaptureAdmission(.failureHandlingStarted(
            captureID: active.session.id
        )) == .preserveFailure(active.session.id) else { return }
        recordingState = .idle
        invalidateCapTimer()
        stopLivePreview()
        _ = audioCapture.stop()
        let message = "Recording stopped because audio could not be saved"
        lastError = message
        recoveryAdmissionStorageHealthy = false
        recoveryHealth = .unavailable(message)
        let service = CaptureJournalService(
            fileSystem: LocalJournalFileSystem(), ledger: recoveryStore
        )
        Task {
            do {
                try await service.preserveFailure(active, message: message)
                guard captureAdmission.state == .finalizing(
                    captureID: active.session.id
                ) else { return }
                _ = reduceCaptureAdmission(.failureHandled(captureID: active.session.id))
                pendingFailurePreservation = nil
                activeCaptureJournal = nil
                captureOwner = .none
                let destination = destinationLifecycle.take()
                if case .scratchpad = destination {
                    _ = try? Self.routeDestinationEvent(
                        .failure(message), destination: destination,
                        router: scratchpadRecordingRouter
                    ) {}
                }
                recordingOutputSelection.resolveTerminal()
                hud.flash("Recording stopped — captured audio kept for recovery")
                recordingHUDDidReachTerminalState()
            } catch {
                guard captureAdmission.state == .finalizing(
                    captureID: active.session.id
                ) else { return }
                let detail = "\(message): \(error.localizedDescription)"
                _ = reduceCaptureAdmission(.cleanupFailed(
                    captureID: active.session.id, message: detail
                ))
                pendingFailurePreservation = PendingFailurePreservation(
                    active: active, service: service, message: message
                )
                lastError = detail
                hud.flash("Recording failure retained — recovery needs attention")
            }
        }
    }

    private func handleMicrophoneSignalDecision(
        _ decision: MicrophoneSignalWatchdog.Decision,
        captureID: UUID
    ) {
        guard captureAdmission.state == .recording(captureID: captureID),
              activeCaptureJournal?.session.id == captureID else { return }
        switch decision {
        case .continueRecording:
            break
        case .warnNoSignal:
            hud.flash("No microphone signal detected yet — recording continues")
        case .restartForRouteFailure(let message):
            do {
                try audioCapture.restartAfterCorroboratedFault()
                hud.flash("Microphone input restarted after a route failure")
            } catch {
                handleJournalConsumerFailure(
                    captureID: captureID,
                    result: .failed("\(message): \(error.localizedDescription)")
                )
            }
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
            warnings: audioCapture.captureWarnings,
            activeTemplateName: activeTemplateName,
            localContextScopeName: contextScope.displayName,
            localContextPermissionHint: contextPermissionHint,
            oneShotLanguage: oneShotLanguage,
            languageOptions: recordingLanguageSnapshot,
            translationState: presentedTranslationState
        )
        recordingHUDWillPresent()
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
    private func makeStopRequest(
        preSnapshotted: (app: NSRunningApplication?, target: InsertionTarget?, contextTarget: ContextTargetSnapshot)?,
        skipPostProcessing: Bool
    ) -> PendingStopRequest {
        let destination = recordingDestination ?? .external
        let snapshot = preSnapshotted ?? Self.externalStopSnapshot(for: destination) {
            let app = NSWorkspace.shared.frontmostApplication
            return (
                app: app,
                target: Insertion.snapshotTarget(app: app),
                contextTarget: snapshotContextTarget(app: app)
            )
        }
        let settings = Self.captureStopSettingsSnapshot(
            oneShotLanguage: oneShotLanguage,
            selectedOutput: recordingOutputSelection.current,
            defaultOutput: AppSettings.shared.defaultOutputLanguage,
            cloudSnapshot: AppSettings.shared.cloudLLMSnapshot
        )
        return PendingStopRequest(
            destination: destination, snapshot: snapshot,
            skipPostProcessing: skipPostProcessing,
            oneShotLanguage: settings.oneShotLanguage,
            outputLanguage: settings.outputLanguage,
            cloudSnapshot: settings.cloudSnapshot
        )
    }

    private func stopAndTranscribe(
        preSnapshotted: (app: NSRunningApplication?, target: InsertionTarget?, contextTarget: ContextTargetSnapshot)? = nil,
        skipPostProcessing: Bool = false,
        stoppedCapture: (samples: [Float], peak: Float, rms: Float, staged: StagedCapture?)? = nil,
        stopRequest suppliedStopRequest: PendingStopRequest? = nil
    ) {
        let stopRequest = suppliedStopRequest ?? makeStopRequest(
            preSnapshotted: preSnapshotted,
            skipPostProcessing: skipPostProcessing
        )
        if case .preparing = captureAdmission.state {
            _ = reduceCaptureAdmission(.stopRequested)
            pendingStopRequest = stopRequest
            return
        }

        if stoppedCapture == nil, let active = activeCaptureJournal,
           let recoveryStore {
            guard reduceCaptureAdmission(.stopRequested) == .finish(active.session.id) else {
                return
            }
            journalFailureHandled = true
            invalidateCapTimer()
            stopLivePreview()
            _ = audioCapture.stop()
            let signal = audioCapture.signalDiagnostics()
            let peak = signal.peak
            let rms = signal.rms
            let diagnostics = CaptureDiagnostics(
                peak: peak, rms: rms,
                inputDeviceUID: AppSettings.shared.microphoneDeviceUID,
                routeFailure: signal.routeFailure
            )
            active.writer.updateDiagnostics(diagnostics)
            // Permission Diagnosis's Microphone capture-health signal (PLAN.md F2.1): reuses
            // the exact silence classification the recovery path already applies to this same
            // capture — read-only, no changes to `AudioCapture`'s own watchdog logic.
            microphoneCaptureHealth = diagnostics.indicatesSilence
                ? .noSignal(route: diagnostics.routeFailure)
                : .ok
            let service = CaptureJournalService(
                fileSystem: LocalJournalFileSystem(), ledger: recoveryStore,
                recoveryRoot: Self.recoveryDirectory
            )
            journalFinalizationTask = Task {
                var ownershipTransitionCompleted = false
                do {
                    if diagnostics.indicatesSilence {
                        try await service.recordSilent(active, diagnostics: diagnostics)
                        guard captureAdmission.state == .finalizing(
                            captureID: active.session.id
                        ) else { return }
                        _ = reduceCaptureAdmission(.finalizationFinished(
                            captureID: active.session.id
                        ))
                        journalFinalizationTask = nil
                        activeCaptureJournal = nil
                        captureOwner = .none
                        pendingStopRequest = nil
                        _ = destinationLifecycle.take()
                        recordingOutputSelection.resolveTerminal()
                        lastError = SilentCapturePresentation.message
                        do {
                            try await jobLibraryStore?.refresh()
                        } catch {
                            recoveryHealth = .degraded(
                                "Silent recovery was saved, but the Library could not refresh: \(error.localizedDescription)"
                            )
                        }
                        if case .scratchpad = stopRequest.destination {
                            _ = try? Self.routeDestinationEvent(
                                .failure(SilentCapturePresentation.message),
                                destination: stopRequest.destination,
                                router: scratchpadRecordingRouter
                            ) {}
                        }
                        hud.flash(SilentCapturePresentation.message)
                        recordingHUDDidReachTerminalState()
                        return
                    }
                    let staged = try await service.finish(active)
                    ownershipTransitionCompleted = true
                    let url = staged.canonicalAudioURL
                    let downstreamSamples = try await CaptureCanonicalAudioLoader.load {
                        try CaptureSegmentCodec(
                            fileSystem: LocalJournalFileSystem()
                        ).decode(url)
                    }
                    guard captureAdmission.state == .finalizing(
                        captureID: active.session.id
                    ) else { return }
                    _ = reduceCaptureAdmission(.finalizationFinished(
                        captureID: active.session.id
                    ))
                    journalFinalizationTask = nil
                    activeCaptureJournal = nil
                    captureOwner = .none
                    stopAndTranscribe(
                        stoppedCapture: (downstreamSamples, peak, rms, staged),
                        stopRequest: stopRequest
                    )
                } catch {
                    guard captureAdmission.state == .finalizing(
                        captureID: active.session.id
                    ) else { return }
                    _ = reduceCaptureAdmission(.failureHandled(
                        captureID: active.session.id
                    ))
                    journalFinalizationTask = nil
                    activeCaptureJournal = nil
                    captureOwner = .none
                    let message = "Recording was preserved, but could not be prepared for processing"
                    let detail = "\(message): \(error.localizedDescription)"
                    let classification = RecoveryFinalizationFailurePolicy.classify(
                        ownershipTransitionCompleted: ownershipTransitionCompleted,
                        message: detail
                    )
                    recoveryHealth = classification.health
                    recoveryAdmissionStorageHealthy = classification.admissionStorageHealthy
                    lastError = detail
                    let destination = destinationLifecycle.take()
                    if case .scratchpad = destination {
                        _ = try? Self.routeDestinationEvent(
                            .failure(message), destination: destination,
                            router: scratchpadRecordingRouter
                        ) {}
                    }
                    recordingOutputSelection.resolveTerminal()
                    hud.flash("Recording saved for recovery — processing not started")
                    recordingHUDDidReachTerminalState()
                }
            }
            return
        }

        let capturedOneShotLanguage = stopRequest.oneShotLanguage
        let capturedOutputLanguage = stopRequest.outputLanguage
        let capturedCloudSnapshot = stopRequest.cloudSnapshot
        defer {
            oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear)
            recordingOutputSelection.resolveTerminal()
        }

        _ = destinationLifecycle.take()
        let destination = stopRequest.destination

        if case .scratchpad(let token) = destination {
            stopAndTranscribeToScratchpad(
                token: token, forcedLanguage: capturedOneShotLanguage,
                outputLanguage: capturedOutputLanguage, cloudSnapshot: capturedCloudSnapshot,
                skipPostProcessing: stopRequest.skipPostProcessing,
                stoppedCapture: stoppedCapture
            )
            return
        }

        // The destination and context target are the first stop-time reads. Keep this before
        // audio teardown, logging, file I/O, and every async boundary so later focus changes
        // cannot redirect AX reads or OCR to another window.
        let frontmostApp = stopRequest.snapshot?.app
        let insertionTarget = stopRequest.snapshot?.target
        let contextTarget = stopRequest.snapshot?.contextTarget
            ?? snapshotContextTarget(app: frontmostApp)

        invalidateCapTimer()
        stopLivePreview()
        captureOwner = .none
        let samples = stoppedCapture?.samples ?? audioCapture.stop()

        // Always cheap, always on: peak/RMS tells us in one line whether the mic tap delivered
        // real signal or near-silence, and the WAV lets us listen to exactly what was captured
        // — without it, "transcribed as Thank you" and "captured zero samples" are
        // indistinguishable from the log alone. See live-mic silence investigation.
        let (peak, rms) = stoppedCapture.map { ($0.peak, $0.rms) }
            ?? AudioLevel.peakAndRMS(samples)
        Self.logger.log("capture stopped: samples=\(samples.count) peak=\(peak) rms=\(rms)")
        writeLastCaptureDebugArtifact(samples)

        if let issue = Self.capturedAudioIssue(sampleCount: samples.count, peak: peak, rms: rms) {
            lastError = issue
            hud.flash(issue)
            recordingHUDDidEndEarly(.externalDeadAudio)
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
        let processor = capturedOutputLanguage == .sameAsSpoken ? resolveActiveProcessor() : nil
        // Snapshotted synchronously here, alongside engine/template/appRules above — see that
        // comment block. `recordingLanguageSnapshot`/`recordingPinSnapshot`/
        // `recordingAppLanguageRulesSnapshot` were themselves frozen TOGETHER at Recording start
        // (`beginCapture`, via `captureRecordingLanguageSnapshot`); reading them into locals now
        // (rather than inside the `Task` below) additionally guards against a new Recording
        // starting and overwriting them before the async pipeline task actually runs. The pin and
        // app-language-rules were previously read live from `AppSettings.shared` here — a pin
        // change mid-Recording could retroactively change which language this stop resolves to,
        // contradicting the Dictation Language Set's own start-snapshot semantics. See Codex
        // finding: stop-time live language-pin/appLanguageRules read.
        let candidateLanguages = recordingLanguageSnapshot
        let forcedLanguage = Self.resolveLanguage(
            oneShot: capturedOneShotLanguage,
            bundleID: bundleID,
            appLanguageRules: recordingAppLanguageRulesSnapshot,
            pin: recordingPinSnapshot,
            candidateSet: candidateLanguages
        )

        let hudGeneration = recordingHUDWillPresent()
        hud.show(text: Self.contextPermissionHint(for: contextCapture.limitation) ?? "Processing…")

        guard let recoveryStore else {
            lastError = "Could not save recording for processing"
            hud.flash("Recording could not be saved — transcription not started")
            isProcessing = false
            recordingHUDDidReachTerminalState(generation: hudGeneration)
            return
        }
        guard let staged = stoppedCapture?.staged else {
            lastError = "Durable recording ownership is unavailable"
            hud.flash("Recording saved for recovery — processing not started")
            isProcessing = false
            recordingHUDDidReachTerminalState(generation: hudGeneration)
            return
        }
        let recoveryService = makeJournalRecoveryService(store: recoveryStore)
        Task {
            do {
                let capture = try await recoveryService.registerJournalCapture(
                    staged, capturedAt: Date()
                )
                let recovery = ForegroundRecovery(
                    service: recoveryService, capture: capture,
                    captureID: staged.captureID
                )
                try? await jobLibraryStore?.refresh()
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
                    candidateLanguages: candidateLanguages,
                    outputLanguage: capturedOutputLanguage,
                    cloudSnapshot: capturedCloudSnapshot,
                    skipPostProcessing: stopRequest.skipPostProcessing,
                    processor: processor,
                    localContext: Self.localContextForProcessor(
                        isCloudConfigured: !(processor is AppleFMProcessor),
                        capture: resolvedCapture
                    ),
                    recovery: recovery,
                    bundleID: bundleID,
                    durationSecs: Double(staged.sampleCount) / Double(CaptureSegmentCodec.sampleRate),
                    hudGeneration: hudGeneration
                )
            } catch {
                lastError = "Failed to queue durable recording: \(error.localizedDescription)"
                hud.flash("Recording saved for recovery — processing not started")
                isProcessing = false
                recordingHUDDidReachTerminalState(generation: hudGeneration)
            }
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
        if case .preparing = captureAdmission.state {
            _ = reduceCaptureAdmission(.cancelRequested)
            pendingStopRequest = nil
            stopLivePreview()
            invalidateCapTimer()
            return
        }
        if case .cleanupFailed = captureAdmission.state, activeCaptureJournal == nil {
            hud.flash("Recording preparation still needs recovery")
            return
        }
        if let active = activeCaptureJournal, let recoveryStore {
            cleanupRetryGate.invalidate(captureID: active.session.id)
            cleanupRetryTask?.cancel()
            cleanupRetryTask = nil
            guard reduceCaptureAdmission(.cancelRequested) == .cancel(active.session.id) else {
                return
            }
            journalFailureHandled = true
            journalFinalizationTask?.cancel()
            journalFinalizationTask = nil
            _ = audioCapture.stop()
            stopLivePreview()
            invalidateCapTimer()
            let service = CaptureJournalService(
                fileSystem: LocalJournalFileSystem(), ledger: recoveryStore
            )
            Task { await cleanCancelledAdmission(active, service: service) }
            return
        }
        oneShotLanguage = Self.nextOneShotLanguage(current: oneShotLanguage, event: .clear)
        recordingOutputSelection.resolveTerminal()
        captureOwner = .none
        destinationLifecycle.cancel {
            Self.performCancelRecording(
                stopCapture: { _ = self.audioCapture.stop() },
                cancelLivePreview: { self.stopLivePreview() },
                invalidateCapTimer: { self.invalidateCapTimer() },
                clearHUD: { self.hud.flash("Cancelled") }
            )
        }
        recordingHUDDidReachTerminalState()
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

    /// Reads the three fields `RecordingLanguageSnapshot` bundles together, all at once, from
    /// `settings` — called at each capture-start site (`beginCapture`,
    /// `beginVoiceEditInstructionRecording`) so the freeze happens at exactly the same instant
    /// `recordingLanguageSnapshot` itself is frozen. Takes `settings` as a parameter (rather than
    /// reading `AppSettings.shared` internally) purely so this capture step is testable against
    /// an injected `AppSettings` instance — production call sites always pass `.shared`.
    static func captureRecordingLanguageSnapshot(from settings: AppSettings) -> RecordingLanguageSnapshot {
        RecordingLanguageSnapshot(
            candidateLanguages: settings.dictationLanguages,
            pin: settings.languagePin,
            appLanguageRules: settings.appLanguageRules
        )
    }

    /// `candidateSet`: the Dictation Language Set the oneShot/rule/pin value is validated
    /// against — the set snapshotted at Recording start (`recordingLanguageSnapshot`), NOT
    /// necessarily the live `AppSettings.shared.dictationLanguages` at the moment this runs. The
    /// one-shot selection itself is still read live (it's deliberately a stop-time override —
    /// see `oneShotLanguage`/`handlePanelOneShotLanguage`), but it's validated against this same
    /// snapshotted set so a language removed from the configuration mid-recording can't leak
    /// through as a forced language. See PLAN.md F5.4.
    nonisolated static func resolveLanguage(
        oneShot: String?,
        bundleID: String?,
        appLanguageRules: [String: String],
        pin: String,
        candidateSet: [String]
    ) -> String? {
        if let oneShot, let normalized = AppSettings.normalizeLanguageCode(oneShot, allowed: candidateSet) {
            return normalized
        }
        if let bundleID, let ruleValue = appLanguageRules[bundleID], let normalized = AppSettings.normalizeLanguageCode(ruleValue, allowed: candidateSet) {
            return normalized
        }
        // "auto" (or any other invalid value) normalizes to nil here — auto-detect — which is
        // exactly this function's own final fallback, so no extra branch is needed.
        return AppSettings.normalizeLanguageCode(pin, allowed: candidateSet)
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
        guard let result = try? await whisperEngine.transcribe(samples: window, forcedLanguage: nil, candidateLanguages: recordingLanguageSnapshot, allowEarlyCancel: true) else { return }

        guard Self.shouldAcceptLivePreviewResult(isRecording: isRecording, resultGeneration: generation, currentGeneration: livePreviewGeneration) else { return }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastLivePreviewText else { return }
        lastLivePreviewText = text
        if let destination = recordingDestination {
            _ = try? Self.routeDestinationEvent(.preview(text), destination: destination, router: scratchpadRecordingRouter) {}
        }
        // Recording Panel (Feature 3): the preview text is embedded inside the panel's own row
        // layout in both recording states — a tick must never replace that layout with a bare
        // text pill.
        updateRecordingPanel()
    }

    static func runExternalPipelineTask<Result>(
        operation: () async throws -> Result,
        onSuccess: (Result) async -> Void,
        onCancellation: () async -> Void,
        onEmptyTranscript: () async -> Void,
        onRecordFailure: () async -> Void,
        onTranslationFailure: (OutputTranslationFailure) async -> Void,
        onFailure: (Error) async -> Void
    ) async {
        do {
            await onSuccess(try await operation())
        } catch is CancellationError {
            await onCancellation()
        } catch where Task.isCancelled {
            await onCancellation()
        } catch PipelineError.emptyTranscript {
            await onEmptyTranscript()
        } catch PipelineError.recordFailed(_) {
            await onRecordFailure()
        } catch let failure as OutputTranslationFailure {
            await onTranslationFailure(failure)
        } catch {
            await onFailure(error)
        }
    }

    static func runScratchpadPipelineTask<Result>(
        operation: () async throws -> Result,
        onSuccess: (Result) async -> Void,
        onCancellation: () async -> Void,
        onTranslationFailure: (OutputTranslationFailure) async -> Void,
        onFailure: (Error) async -> Void
    ) async {
        do {
            await onSuccess(try await operation())
        } catch is CancellationError {
            await onCancellation()
        } catch where Task.isCancelled {
            await onCancellation()
        } catch let failure as OutputTranslationFailure {
            await onTranslationFailure(failure)
        } catch {
            await onFailure(error)
        }
    }

    private struct ForegroundRecovery {
        let service: RecoveryCaptureService
        let capture: ProvisionalRecoveryCapture
        let captureID: UUID
    }

    nonisolated static func stageCaptureBeforeLaunching<Capture>(
        samples: [Float],
        stage: ([Float]) throws -> Capture,
        launch: (Capture) -> Void
    ) rethrows {
        launch(try stage(samples))
    }

    private func makeJournalRecoveryService(
        store: TranscriptionJobStore
    ) -> RecoveryCaptureService {
        RecoveryCaptureService(
            directory: Self.recoveryDirectory,
            store: store,
            ledger: store,
            journalFileSystem: LocalJournalFileSystem(),
            libraryDictationID: { captureID in
                try await MainActor.run {
                    try LibraryStore.shared.dictations(captureID: captureID).first?.id
                }
            }
        )
    }

    private func failForegroundRecovery(_ recovery: ForegroundRecovery, failure: JobFailure) async {
        do {
            try await recovery.service.failProvisional(recovery.capture, failure: failure)
            try? await jobLibraryStore?.refresh()
        } catch {
            lastError = "Failed to finalize recovery audio: \(error.localizedDescription)"
        }
    }

    private func completeForegroundRecovery(_ recovery: ForegroundRecovery) async -> Bool {
        do {
            try await recovery.service.completeJournalCapture(
                recovery.capture, captureID: recovery.captureID
            )
            try? await jobLibraryStore?.refresh()
            return true
        } catch {
            lastError = "Dictation saved, but recovery cleanup failed: \(error.localizedDescription)"
            try? await jobLibraryStore?.refresh()
            return false
        }
    }

    private func runPipeline(samples: [Float], engine: any TranscriptionEngine, engineName: String, template: Template, appName: String?, target: InsertionTarget?, forcedLanguage: String?, candidateLanguages: [String], outputLanguage: OutputLanguage, cloudSnapshot: CloudLLMSettingsSnapshot, skipPostProcessing: Bool, processor: (any PostProcessor)? = nil, localContext: LocalProcessingContext? = nil, recovery: ForegroundRecovery, bundleID: String?, durationSecs: Double?, hudGeneration: UUID) async {
        defer {
            isProcessing = false
            recordingHUDDidReachTerminalState(generation: hudGeneration)
        }

        await Self.runExternalPipelineTask(
            operation: {
                try await processDictation(
                    samples: samples, engine: engine, engineName: engineName, template: template,
                    appName: appName, target: target, forcedLanguage: forcedLanguage,
                    candidateLanguages: candidateLanguages,
                    skipPostProcessing: skipPostProcessing, outputLanguage: outputLanguage,
                    cloudSnapshot: cloudSnapshot.eligibility.isEligible ? cloudSnapshot : nil,
                    processor: processor, localContext: localContext,
                    record: { result in
                        try LibraryStore.shared.record(
                            language: result.sourceLanguage.rawValue,
                            requestedOutputLanguage: result.requestedOutputLanguage,
                            template: result.templateName,
                            transcript: result.rawTranscript,
                            refined: result.finalOutput,
                            engine: result.engineName,
                            captureID: recovery.captureID,
                            bundleID: bundleID,
                            durationSecs: durationSecs
                        )
                    }
                )
            },
            onSuccess: { result in
                guard await completeForegroundRecovery(recovery) else {
                    hud.flash("Dictation saved — recovery cleanup failed")
                    return
                }
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
            },
            onCancellation: {
                await failForegroundRecovery(recovery, failure: JobFailure(
                    stage: .transcribing,
                    message: "Processing was interrupted"
                ))
                hud.flash("Processing interrupted — audio saved")
            },
            onEmptyTranscript: {
                await failForegroundRecovery(recovery, failure: JobFailure(stage: .transcribing, message: "Empty transcript"))
                hud.flash("Transcription failed — audio saved")
            },
            onRecordFailure: {
                await failForegroundRecovery(recovery, failure: JobFailure(stage: .persisting, message: "Library save failed"))
                hud.flash("Library save failed — audio saved")
            },
            onTranslationFailure: { failure in
                await failForegroundRecovery(recovery, failure: JobFailure(
                    stage: .postProcessing,
                    message: failure.localizedDescription
                ))
                let message = handleOutputTranslationFailure(failure, externalTarget: target)
                lastError = message
            },
            onFailure: { error in
                lastError = "Transcription failed: \(error.localizedDescription)"
                await failForegroundRecovery(recovery, failure: JobFailure(stage: .transcribing, message: error.localizedDescription))
                hud.flash("Transcription failed — audio saved")
            }
        )
    }

    private func stopAndTranscribeToScratchpad(
        token: ScratchpadInsertionToken,
        forcedLanguage oneShotLanguage: String?,
        outputLanguage: OutputLanguage,
        cloudSnapshot: CloudLLMSettingsSnapshot,
        skipPostProcessing: Bool,
        stoppedCapture: (samples: [Float], peak: Float, rms: Float, staged: StagedCapture?)?
    ) {
        invalidateCapTimer()
        stopLivePreview()
        _ = try? Self.routeDestinationEvent(.preview(nil), destination: .scratchpad(token), router: scratchpadRecordingRouter) {}
        captureOwner = .none
        let samples = stoppedCapture?.samples ?? audioCapture.stop()
        let (peak, rms) = stoppedCapture.map { ($0.peak, $0.rms) }
            ?? AudioLevel.peakAndRMS(samples)
        if let issue = Self.capturedAudioIssue(sampleCount: samples.count, peak: peak, rms: rms) {
            lastError = issue
            hud.flash(issue)
            let delivered = (try? Self.routeDestinationEvent(
                .failure(issue),
                destination: .scratchpad(token),
                router: scratchpadRecordingRouter
            ) {}) ?? false
            if !delivered { destinationLifecycle.storePendingFailure(issue) }
            recordingHUDDidEndEarly(.scratchpadDeadAudio)
            return
        }

        let engine = activeSTTEngine
        let engineName = engine.name
        let template = TemplateStore.shared.template(id: AppSettings.shared.activeTemplateID)
            ?? Template.builtIns.first!
        let forcedLanguage = Self.resolveLanguage(
            oneShot: oneShotLanguage,
            bundleID: nil,
            appLanguageRules: [:],
            pin: recordingPinSnapshot,
            candidateSet: recordingLanguageSnapshot
        )
        isProcessing = true
        let hudGeneration = recordingHUDWillPresent()
        hud.show(text: "Processing…")
        let context = RecordingProcessingContext(
            destination: .scratchpad(token), spokenLanguage: forcedLanguage,
            outputLanguage: outputLanguage, template: template,
            cloudSnapshot: cloudSnapshot.eligibility.isEligible ? cloudSnapshot : nil,
            candidateLanguages: recordingLanguageSnapshot
        )
        let processor = outputLanguage == .sameAsSpoken ? resolveActiveProcessor() : nil

        guard let recoveryStore else {
            lastError = "Could not save recording for processing"
            hud.flash("Recording could not be saved — transcription not started")
            isProcessing = false
            recordingHUDDidReachTerminalState(generation: hudGeneration)
            return
        }
        guard let staged = stoppedCapture?.staged else {
            lastError = "Durable recording ownership is unavailable"
            hud.flash("Recording saved for recovery — processing not started")
            isProcessing = false
            recordingHUDDidReachTerminalState(generation: hudGeneration)
            return
        }
        let recoveryService = makeJournalRecoveryService(store: recoveryStore)
        Task {
            do {
                defer {
                    isProcessing = false
                    recordingHUDDidReachTerminalState(generation: hudGeneration)
                }
                let capture = try await recoveryService.registerJournalCapture(
                    staged, capturedAt: Date()
                )
                let recovery = ForegroundRecovery(
                    service: recoveryService, capture: capture,
                    captureID: staged.captureID
                )
                try? await jobLibraryStore?.refresh()
                await Self.runScratchpadPipelineTask(
                            operation: {
                                try await destinationLifecycle.runAsync(
                                    destination: .scratchpad(token),
                                    process: {
                                        try await transcribeAndRefine(
                                            samples: samples, engine: engine, engineName: engineName,
                                            context: context, appName: nil,
                                            skipPostProcessing: skipPostProcessing, processor: processor,
                                            translator: TranslationService(), localContext: nil
                                        )
                                    },
                                    text: { $0.refined },
                                    external: { _ in }
                                )
                            },
                            onSuccess: { result, accepted in
                                do {
                                    try LibraryStore.shared.record(
                                        language: result.language,
                                        requestedOutputLanguage: outputLanguage,
                                        template: result.recordedTemplateName,
                                        transcript: result.transcript,
                                        refined: result.refined,
                                        engine: result.engineName,
                                        captureID: staged.captureID,
                                        durationSecs: Double(staged.sampleCount) / Double(CaptureSegmentCodec.sampleRate)
                                    )
                                } catch {
                                    await failForegroundRecovery(
                                        recovery,
                                        failure: JobFailure(
                                            stage: .persisting,
                                            message: "Library save failed"
                                        )
                                    )
                                    hud.flash("Library save failed — audio saved")
                                    return
                                }
                                guard await completeForegroundRecovery(recovery) else {
                                    hud.flash("Dictation ready — recovery cleanup failed")
                                    return
                                }
                                if let fallbackReason = result.fallbackReason {
                                    logPostProcessingFallback(fallbackReason)
                                }
                                if accepted {
                                    hud.hide()
                                } else {
                                    hud.flash("Dictation ready — reopen Scratchpad to recover it")
                                }
                            },
                            onCancellation: {
                                await failForegroundRecovery(recovery, failure: JobFailure(
                                    stage: .transcribing,
                                    message: "Processing was interrupted"
                                ))
                            },
                            onTranslationFailure: { failure in
                                await failForegroundRecovery(recovery, failure: JobFailure(
                                    stage: .postProcessing,
                                    message: failure.localizedDescription
                                ))
                                let message = handleOutputTranslationFailure(failure)
                                lastError = message
                            },
                            onFailure: { error in
                                let message = error is PipelineError ? "Transcription failed" : "Transcription failed: \(error.localizedDescription)"
                                lastError = message
                                await failForegroundRecovery(recovery, failure: JobFailure(
                                    stage: .transcribing,
                                    message: error.localizedDescription
                                ))
                                hud.flash(message)
                            }
                )
            } catch {
                lastError = "Failed to queue durable recording: \(error.localizedDescription)"
                hud.flash("Recording saved for recovery — processing not started")
                isProcessing = false
                recordingHUDDidReachTerminalState(generation: hudGeneration)
            }
        }
    }

    enum PipelineError: Error {
        case emptyTranscript
        case recordFailed(Error)
    }

    enum PipelineFailureKind: Equatable {
        case transcription
        case translation
    }

    nonisolated static func pipelineFailureKind(_ error: Error) -> PipelineFailureKind {
        error is OutputTranslationFailure ? .translation : .transcription
    }

    enum PostProcessingFallbackReason {
        case error(Error)
        case emptyOutput
    }

    private struct DictationProcessingResult {
        let transcript: String
        let refined: String
        let language: String
        let recordedTemplateName: String
        let engineName: String
        let fallbackReason: PostProcessingFallbackReason?
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
        candidateLanguages: [String] = [],
        skipPostProcessing: Bool = false,
        outputLanguage: OutputLanguage = .sameAsSpoken,
        cloudSnapshot: CloudLLMSettingsSnapshot? = nil,
        processor: (any PostProcessor)? = nil,
        translator: any Translating = TranslationService(),
        localContext: LocalProcessingContext? = nil,
        insert: (String, InsertionTarget?) -> Bool = { Insertion.insert($0, target: $1).posted },
        record: (RecordingProcessingResult) throws -> Void = { result in
            try LibraryStore.shared.record(
                language: result.sourceLanguage.rawValue,
                requestedOutputLanguage: result.requestedOutputLanguage,
                template: result.templateName,
                transcript: result.rawTranscript,
                refined: result.finalOutput,
                engine: result.engineName
            )
        }
    ) async throws -> RecordingProcessingResult {
        let context = RecordingProcessingContext(
            destination: .external,
            spokenLanguage: forcedLanguage,
            outputLanguage: outputLanguage,
            template: template,
            cloudSnapshot: cloudSnapshot,
            candidateLanguages: candidateLanguages
        )
        return try await processDictation(
            samples: samples, engine: engine, engineName: engineName, context: context,
            appName: appName, target: target, skipPostProcessing: skipPostProcessing,
            processor: processor, translator: translator, localContext: localContext,
            insert: insert, record: record
        )
    }

    @discardableResult
    func processDictation(
        samples: [Float],
        engine: any TranscriptionEngine,
        engineName: String,
        context: RecordingProcessingContext,
        appName: String? = nil,
        target: InsertionTarget? = nil,
        skipPostProcessing: Bool = false,
        processor: (any PostProcessor)? = nil,
        translator: any Translating = TranslationService(),
        localContext: LocalProcessingContext? = nil,
        insert: (String, InsertionTarget?) -> Bool = { Insertion.insert($0, target: $1).posted },
        record: (RecordingProcessingResult) throws -> Void = { result in
            try LibraryStore.shared.record(
                language: result.sourceLanguage.rawValue,
                requestedOutputLanguage: result.requestedOutputLanguage,
                template: result.templateName,
                transcript: result.rawTranscript,
                refined: result.finalOutput,
                engine: result.engineName
            )
        }
    ) async throws -> RecordingProcessingResult {
        var posted = false
        let (result, _) = try await destinationLifecycle.runAsync(
            destination: context.destination,
            process: {
                try await transcribeAndRefine(
                    samples: samples, engine: engine, engineName: engineName,
                    context: context, appName: appName, skipPostProcessing: skipPostProcessing,
                    processor: processor, translator: translator, localContext: localContext
                )
            },
            text: { $0.refined },
            external: { result in
                posted = insert(result.refined, target)
                let delivered = RecordingProcessingResult(
                    rawTranscript: result.transcript, finalOutput: result.refined,
                    sourceLanguage: SourceLanguage(result.language),
                    requestedOutputLanguage: context.outputLanguage,
                    templateName: result.recordedTemplateName, engineName: result.engineName,
                    posted: posted, fallbackReason: result.fallbackReason
                )
                do { try record(delivered) }
                catch { throw PipelineError.recordFailed(error) }
            }
        )
        return RecordingProcessingResult(
            rawTranscript: result.transcript, finalOutput: result.refined,
            sourceLanguage: SourceLanguage(result.language),
            requestedOutputLanguage: context.outputLanguage,
            templateName: result.recordedTemplateName, engineName: result.engineName,
            posted: posted, fallbackReason: result.fallbackReason
        )
    }

    private func transcribeAndRefine(
        samples: [Float],
        engine: any TranscriptionEngine,
        engineName: String,
        context: RecordingProcessingContext,
        appName: String?,
        skipPostProcessing: Bool,
        processor: (any PostProcessor)?,
        translator: any Translating,
        localContext: LocalProcessingContext?
    ) async throws -> DictationProcessingResult {
        let transcription = try await engine.transcribe(samples: samples, forcedLanguage: context.transcriptionLanguage, candidateLanguages: context.candidateLanguages)
        guard !transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError.emptyTranscript
        }

        let refined: String
        var fallbackReason: PostProcessingFallbackReason?
        let recordedTemplateName: String
        if skipPostProcessing {
            refined = transcription.text
            recordedTemplateName = TemplateStore.rawTranscriptTemplateName
        } else if case .translate = context.outputLanguage.processingPolicy {
            let failureContext = RecordingProcessingContext(
                destination: context.destination,
                spokenLanguage: transcription.language,
                outputLanguage: context.outputLanguage,
                template: context.template,
                cloudSnapshot: context.cloudSnapshot,
                candidateLanguages: context.candidateLanguages
            )
            guard let snapshot = context.cloudSnapshot, snapshot.eligibility.isEligible else {
                throw OutputTranslationFailure(
                    source: transcription.text, context: failureContext,
                    engineName: engineName,
                    underlyingError: TranslationService.Error.unavailable(.invalidConfiguration)
                )
            }
            do {
                refined = try await translator.process(
                    source: transcription.text,
                    template: context.template,
                    policy: context.outputLanguage.processingPolicy,
                    snapshot: snapshot
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw OutputTranslationFailure(
                    source: transcription.text, context: failureContext,
                    engineName: engineName, underlyingError: error
                )
            }
            recordedTemplateName = context.template.name
        } else {
            let activeProcessor: any PostProcessor = processor ?? resolveActiveProcessor()
            do {
                let processed: String
                let request = PostProcessingRequest(
                    transcript: transcription.text,
                    template: context.template,
                    appName: appName,
                    languagePolicy: .preserveSource
                )
                if let localProcessor = activeProcessor as? AppleFMProcessor, let localContext {
                    processed = try await localProcessor.process(
                        request: request,
                        context: localContext
                    )
                } else {
                    processed = try await activeProcessor.process(request)
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
            recordedTemplateName = context.template.name
        }

        return DictationProcessingResult(
            transcript: transcription.text,
            refined: refined,
            language: transcription.language,
            recordedTemplateName: recordedTemplateName,
            engineName: engineName,
            fallbackReason: fallbackReason
        )
    }

    private static let applicationSupportDirectory = FreeTalkerPaths.applicationSupport

    private static var recoveryDirectory: URL {
        FreeTalkerPaths.recoveryDirectory
    }

    private static var mediaImportsDirectory: URL {
        FreeTalkerPaths.mediaImportsDirectory
    }

    private static func makeRecoveryStore() throws -> TranscriptionJobStore {
        try FreeTalkerPaths.requireValidConfiguration()
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        return try TranscriptionJobStore(
            databaseURL: FreeTalkerPaths.jobsDatabase,
            clock: SystemJobClock()
        )
    }

    private static func makeSnippetStore() throws -> SnippetStore {
        try FreeTalkerPaths.requireValidConfiguration()
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        return try SnippetStore(databaseURL: FreeTalkerPaths.snippetsDatabase)
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

    func launchRecoveryWorkflows() async {
        await recoveryLaunchGate.run { [weak self] in
            await self?.performLaunchRecoveryWorkflows()
        }
    }

    func retryRecoverySetup() {
        switch recoverySetupRetryScheduler.request(
            isBusy: recoverySetupRetryIsBusy
        ) {
        case .deferred, .none:
            return
        case .run:
            break
        }
        startRecoverySetupRetry()
    }

    var recoverySetupRetryIsBusy: Bool {
        recoverySetupRetryInFlight
            || captureAdmission.state.isActive
            || captureOwner != .none
            || journalFinalizationTask != nil
            || isRecording
            || isProcessing
    }

    private func runDeferredRecoverySetupRetryIfPossible() {
        guard recoverySetupRetryScheduler.becameIdle(
            isBusy: recoverySetupRetryIsBusy
        ) == .run else { return }
        startRecoverySetupRetry()
    }

    private func startRecoverySetupRetry() {
        Task { [weak self] in
            guard let self else { return }
            await recoveryLaunchGate.run { [weak self] in
                await self?.performRetryRecoverySetup()
            }
        }
    }

    private func performRetryRecoverySetup() async {
        guard !recoverySetupRetryIsBusy else {
            _ = recoverySetupRetryScheduler.request(isBusy: true)
            return
        }
        recoverySetupRetryInFlight = true
        defer { recoverySetupRetryInFlight = false }
        recoveryHealth = recoveryHealth.beginRetry()
        recoveryAdmissionStorageHealthy = false
        do {
            await recoveryRunner?.shutdown()
            await mediaImportRunner?.shutdown()
            let reopened = try RecoveryStoreRetry.openFresh(
                replacing: recoveryStore,
                open: Self.makeRecoveryStore,
                validate: { _ in }
            )
            _ = try await reopened.jobs(kind: .recovery)
            _ = try await reopened.unfinishedSessions()
            recoveryRunner = nil
            mediaImportRunner = nil
            recoveryStore = reopened
            jobLibraryStore = JobLibraryStore(
                store: reopened, recoveryDirectory: Self.recoveryDirectory
            )
            recoveryStoreInitializationError = nil
        } catch {
            let message = error.localizedDescription
            recoveryStoreInitializationError = message
            recoveryHealth = .unavailable(message)
            lastError = "Recovery storage needs attention: \(message)"
            return
        }
        await performLaunchRecoveryWorkflows(isRetry: true)
        await launchMediaImportWorkflows()
        await resolveReconciledCaptureAdmissionIfPossible()
    }

    private func performLaunchRecoveryWorkflows(isRetry: Bool = false) async {
        recoveryHealth = .initializing
        recoveryAdmissionStorageHealthy = false
        guard let recoveryStore else {
            let message = recoveryStoreInitializationError ?? "Recovery store is unavailable"
            recoveryReconciliationReport = RecoveryReconciliationReport(storeFailure: message)
            recoveryHealth = .unavailable(message)
            lastError = "Recovery storage needs attention: \(message)"
            return
        }
        let reconciler = RecoveryReconciler(
            directory: Self.recoveryDirectory,
            store: recoveryStore,
            ledger: recoveryStore,
            libraryDictationID: { captureID in
                try await MainActor.run {
                    try LibraryStore.shared.dictations(captureID: captureID).first?.id
                }
            }
        )
        var reconciliation = await reconciler.reconcile()
        recoveryReconciliationReport = reconciliation
        recoveryAdmissionStorageHealthy = reconciliation.storeFailure == nil
        updateRecoveryHealth(from: reconciliation)
        if let failure = reconciliation.storeFailure {
            lastError = "Recovery reconciliation needs attention: \(failure)"
        } else if reconciliation.failed > 0 {
            lastError = "Recovery reconciliation could not restore \(reconciliation.failed) item(s)"
        }
        if recoveryRunner != nil {
            do {
                try await jobLibraryStore?.refresh()
            } catch {
                reconciliation.recordFailure(Self.recoveryDirectory, error)
                recoveryReconciliationReport = reconciliation
                updateRecoveryHealth(from: reconciliation)
            }
            return
        }
        let pipeline = RecoveryRetryPipeline(
            directory: Self.recoveryDirectory,
            store: recoveryStore,
            processDictation: { [weak self] samples, configuration, captureID in
                guard let self else { throw CancellationError() }
                return try await self.processRecoveredDictation(
                    samples: samples, configuration: configuration,
                    captureID: captureID
                )
            },
            errorStage: { error in
                if case PipelineError.recordFailed = error { return .persisting }
                return .transcribing
            },
            libraryDictationID: { captureID in
                try await MainActor.run {
                    try LibraryStore.shared.dictations(captureID: captureID).first?.id
                }
            },
            finalizeJournalCapture: { [weak self] captureID, _ in
                guard let self,
                      let job = try await recoveryStore.job(id: captureID),
                      try await recoveryStore.session(id: captureID) != nil else {
                    return false
                }
                let service = await self.makeJournalRecoveryService(store: recoveryStore)
                try await service.completeJournalCapture(
                    ProvisionalRecoveryCapture(id: job.id, source: job.source),
                    captureID: captureID
                )
                return true
            }
        )
        let runner = LocalJobRunner(
            store: recoveryStore,
            kind: .recovery,
            executorFinalizesJob: true,
            finalizationFailure: pipeline.failFinalization,
            didChange: { [weak jobLibraryStore] _ in
                do { try await jobLibraryStore?.refresh() }
                catch { print("FreeTalker: recovery Library refresh failed: \(error)") }
            },
            executionAuthority: localJobExecutionAuthority
        ) { job, token in
            try await pipeline.execute(jobID: job.id, configuration: nil, cancellation: token)
        }
        recoveryRunner = runner
        jobLibraryStore?.configureRetry { [weak runner] id in await runner?.enqueue(id) }
        jobLibraryStore?.configureStartNewRecording { [weak self] in
            self?.startHandsFreeRecording(destination: .external) ?? false
        }
        await pipeline.retryPendingSourceCleanup()
        do {
            _ = try await recoveryStore.recoverInterruptedJobs(kind: .recovery)
        } catch {
            reconciliation.recordFailure(Self.recoveryDirectory, error)
        }
        do {
            _ = try await RecoveryRetentionService(
                directory: Self.recoveryDirectory, store: recoveryStore, ledger: recoveryStore
            )
                .purgeExpired(now: Date(), retention: AppSettings.shared.recoveryRetention)
        } catch {
            reconciliation.recordFailure(Self.recoveryDirectory, error)
        }
        recoveryReconciliationReport = reconciliation
        updateRecoveryHealth(from: reconciliation)
        await runner.resumeQueuedJobs()
        do {
            try await jobLibraryStore?.refresh()
        } catch {
            reconciliation.recordFailure(Self.recoveryDirectory, error)
            recoveryReconciliationReport = reconciliation
            updateRecoveryHealth(from: reconciliation)
        }
    }

    private func updateRecoveryHealth(from report: RecoveryReconciliationReport) {
        let failures = report.failures.map(\.message)
        let ownedFailure: String? = if case .cleanupFailed(_, let message) = captureAdmission.state {
            message
        } else if pendingCaptureCleanup != nil || pendingFailurePreservation != nil {
            lastError ?? "A captured recording still needs recovery cleanup."
        } else {
            nil
        }
        recoveryHealth = RecoveryHealth.resolve(
            storeFailure: report.storeFailure,
            itemFailures: failures,
            ownedFailure: ownedFailure
        )
        if case .unavailable = recoveryHealth {
            recoveryAdmissionStorageHealthy = false
        }
    }

    private func resolveReconciledCaptureAdmissionIfPossible() async {
        guard case .cleanupFailed(let captureID, _) = captureAdmission.state,
              pendingCaptureCleanup == nil,
              pendingFailurePreservation == nil,
              let recoveryStore else { return }
        do {
            guard try await recoveryStore.session(id: captureID) != nil else { return }
            _ = reduceCaptureAdmission(.failureHandled(captureID: captureID))
            activeCaptureJournal = nil
            captureOwner = .none
            if let report = recoveryReconciliationReport {
                updateRecoveryHealth(from: report)
            }
        } catch {
            let message = "Recovery ownership could not be verified: \(error.localizedDescription)"
            recoveryAdmissionStorageHealthy = false
            recoveryHealth = .unavailable(message)
            lastError = message
        }
    }

    func launchMediaImportWorkflows() async {
        guard mediaImportRunner == nil, let recoveryStore, let jobLibraryStore else { return }
        do {
            try FileManager.default.createDirectory(at: Self.mediaImportsDirectory, withIntermediateDirectories: true)
        } catch {
            lastError = "Could not prepare local media imports: \(error.localizedDescription)"
            return
        }
        let service = MediaImportService(store: recoveryStore)
        // `resolveLanguageSettings` is called by the pipeline at each job's start, not once here
        // at pipeline construction — see `MediaImportPipeline`'s doc comment. Settings changes
        // made while an earlier queued job is running apply to the next job to start.
        let pipeline = MediaImportPipeline(
            store: recoveryStore,
            jobsDirectory: Self.mediaImportsDirectory,
            decoder: service,
            transcriber: TimestampedWhisperTranscriber(backend: whisperEngine),
            diarizer: LocalFluidAudioDiarizer(),
            resolveLanguageSettings: {
                await MainActor.run {
                    let settings = AppSettings.shared
                    return MediaImportLanguageSettings(
                        language: settings.languagePin == "auto" ? nil : settings.languagePin,
                        model: settings.whisperModel,
                        candidateLanguages: settings.dictationLanguages
                    )
                }
            }
        )
        let runner = pipeline.localJobRunner(executionAuthority: localJobExecutionAuthority) { [weak jobLibraryStore] _ in
            try? await jobLibraryStore?.refresh()
        }
        mediaImportRunner = runner
        jobLibraryStore.configureImports(
            service: service,
            directory: Self.mediaImportsDirectory,
            enqueue: { [weak runner] id in await runner?.enqueue(id) },
            cancel: { [weak runner] id in await runner?.cancel(id) ?? .notRunning }
        )
        await purgeMediaImports(retention: AppSettings.shared.mediaImportRetention)
        await runner.resumeQueuedJobs()
        try? await jobLibraryStore.refresh()
    }

    static func routeMediaImportRetentionChange(
        _ retention: MediaImportRetention,
        purge: @Sendable (MediaImportRetention) async -> Void
    ) async {
        await purge(retention)
    }

    private func purgeMediaImports(retention: MediaImportRetention) async {
        guard let recoveryStore else { return }
        let imports = (try? await recoveryStore.jobs(kind: .mediaImport)) ?? []
        for job in retention.purgeCandidates(imports, now: Date()) {
            try? await recoveryStore.deleteMediaImport(jobID: job.id, jobsDirectory: Self.mediaImportsDirectory)
        }
        try? await jobLibraryStore?.refresh()
    }

    private func processRecoveredDictation(
        samples: [Float],
        configuration: AttemptConfiguration,
        captureID: UUID
    ) async throws -> RecoveryDictation {
        let template = TemplateStore.shared.templates.first {
            $0.id == configuration.template || $0.name == configuration.template
        } ?? TemplateStore.shared.template(id: AppSettings.shared.activeTemplateID) ?? Template.builtIns[0]
        let transcription = try await RecoveryLocalProcessor(transcriber: whisperEngine).process(
            samples: samples,
            configuration: configuration,
            candidateLanguages: AppSettings.shared.dictationLanguages,
            defaultModel: AppSettings.shared.whisperModel
        )
        let dictation = RecoveryDictation(
            language: transcription.language,
            template: template.name,
            transcript: transcription.text,
            refined: transcription.text,
            engine: "WhisperKit"
        )
        try Self.persistRecoveredDictation(dictation, captureID: captureID)
        return dictation
    }

    static func persistRecoveredDictation(
        _ dictation: RecoveryDictation,
        captureID: UUID? = nil,
        record: ((RecoveryDictation) throws -> Void)? = nil
    ) throws {
        do {
            if let record {
                try record(dictation)
            } else {
                try LibraryStore.shared.record(
                    language: dictation.language,
                    template: dictation.template,
                    transcript: dictation.transcript,
                    refined: dictation.refined,
                    engine: dictation.engine,
                    captureID: captureID
                )
            }
        } catch {
            throw PipelineError.recordFailed(error)
        }
    }

    private func purgeRecoveries(retention: RecoveryRetention) async {
        guard let recoveryStore else { return }
        _ = try? await RecoveryRetentionService(
            directory: Self.recoveryDirectory, store: recoveryStore, ledger: recoveryStore
        )
            .purgeExpired(now: Date(), retention: retention)
        try? await jobLibraryStore?.refresh()
    }

    private func scheduleRecoveryRetentionPurge(_ retention: RecoveryRetention) {
        recoveryRetentionTask?.cancel()
        recoveryRetentionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await Self.routeRecoveryRetentionChange(retention) { [weak self] value in
                await self?.purgeRecoveries(retention: value)
            }
        }
    }

    static func routeRecoveryRetentionChange(
        _ retention: RecoveryRetention,
        purge: @Sendable (RecoveryRetention) async -> Void
    ) async { await purge(retention) }

    /// Overwrites `~/Library/Application Support/FreeTalker/last-dictation.wav` with the most
    /// recently captured audio, regardless of whether transcription succeeded. Cheap debug
    /// artifact for the live-mic silence investigation — lets the captured signal be inspected
    /// (played back, or peak/RMS-measured externally) without reproducing the bug interactively.
    private func writeLastCaptureDebugArtifact(_ samples: [Float]) {
        let dir = FreeTalkerPaths.applicationSupport
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
            try data.write(to: FreeTalkerPaths.debugAudio)
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
            let processed = try await processor.process(
                .init(
                    transcript: dictation.transcript,
                    template: template,
                    appName: nil,
                    languagePolicy: .preserveSource
                )
            )
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
        let reprocessOutcome = Insertion.insert(refined)
        if reprocessOutcome.isPermissionClassFailure { refreshPermissionDiagnosis() }
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
                sourceID: dictation.sourceID ?? dictation.id,
                bundleID: dictation.bundleID,
                durationSecs: dictation.durationSecs
            )
        } catch {
            hud.flash("Library save failed")
            return
        }
        if let fallbackReason {
            reportPostProcessingFallback(fallbackReason)
        }
    }

    enum InsertLastDictationAction: Equatable {
        /// `isRecording` or `isProcessing` was true — the insert is silently ignored while active.
        case ignored
        case nothingToInsert
        case libraryUnavailable
        case insert(refined: String)
    }

    /// Guard + outcome decision for `insertLastDictation()`. `fetchResult` is only consulted once
    /// the active-recording/processing guard passes — matching `insertLastDictation()`, which
    /// skips the Database lookup entirely while active.
    nonisolated static func insertLastDictationAction(isRecording: Bool, isProcessing: Bool, fetchResult: Result<Dictation?, Error>) -> InsertLastDictationAction {
        guard !isRecording, !isProcessing else { return .ignored }
        switch fetchResult {
        case .failure:
            return .libraryUnavailable
        case .success(let dictation):
            guard let dictation else { return .nothingToInsert }
            return .insert(refined: dictation.refined)
        }
    }

    /// The HUD message `insertLastDictation()` shows after attempting to insert the newest
    /// Library entry's Refined Output — mirrors the existing "posted vs. not" wording
    /// `runPipeline` uses for the same distinction (manual-paste fallback, `Insertion.insert`'s
    /// `Bool` result), so a failed synthetic paste (text left on the pasteboard only) is never
    /// reported to the user as if it had actually landed at the cursor. See Round 1 Codex
    /// finding 9.
    nonisolated static func insertLastDictationResultMessage(posted: Bool) -> String {
        posted ? "Inserted" : "Copied — paste manually"
    }

    func insertLastDictation() {
        // Skip the Database lookup entirely while active — `insertLastDictationAction` ignores
        // `fetchResult` in that branch anyway, so `.success(nil)` here is just a placeholder.
        let fetchResult: Result<Dictation?, Error> = (isRecording || isProcessing)
            ? .success(nil)
            : Result { try LibraryStore.shared.latestDictation() }
        switch Self.insertLastDictationAction(isRecording: isRecording, isProcessing: isProcessing, fetchResult: fetchResult) {
        case .ignored:
            break
        case .nothingToInsert:
            hud.flash("No dictation to insert yet")
        case .libraryUnavailable:
            hud.flash("Library unavailable")
        case .insert(let refined):
            let outcome = Insertion.insert(refined)
            if outcome.isPermissionClassFailure { refreshPermissionDiagnosis() }
            hud.flash(Self.insertLastDictationResultMessage(posted: outcome.posted))
        }
    }

    /// Dictation History Quick Panel hotkey handler (PLAN.md F3.2): `target` is the
    /// `InsertionTarget` `HotKeyManager` already snapshotted SYNCHRONOUSLY in the tap callback,
    /// before the `Task` hop that delivers this closure — see `HotKeyManager.onHistoryPanelKeyDown`.
    /// The recording gate itself is enforced by `HistoryPanelController.open`.
    private func handleHistoryPanelHotKey(target: InsertionTarget?) {
        HistoryPanelController.shared.open(target: target)
    }

    /// Menu-bar "Dictation History…" fallback (PLAN.md F3.1/F3.2): uses the tracked last
    /// non-FreeTalker frontmost app rather than `NSWorkspace.shared.frontmostApplication`, since
    /// clicking the menu item has already activated FreeTalker by the time this runs.
    ///
    /// `lastNonSelfFrontmostTarget` is only refreshed on app ACTIVATION
    /// (`NSWorkspace.didActivateApplicationNotification`) — same-app document/tab/field changes
    /// since that activation (a different Slack channel, a different Mail draft) leave it
    /// pointing at a stale focused element. Re-querying the tracked app's CURRENT focused AX
    /// element right before opening keeps the app identity already tracked but refreshes the
    /// element/window `Insertion.insert`'s own drift guard compares against. See Codex finding:
    /// stale AX target for menu-opened panel.
    func openHistoryPanelFromMenu() {
        HistoryPanelController.shared.open(target: Self.refreshedTarget(
            stale: lastNonSelfFrontmostTarget,
            refresh: { stale in
                guard let app = NSRunningApplication(processIdentifier: stale.pid) else { return nil }
                return Insertion.snapshotTarget(app: app)
            }
        ))
    }

    /// Re-snapshots `stale`'s tracked app via `refresh`, falling back to `stale` unchanged if the
    /// app can no longer be found or re-snapshotted (e.g. it quit) — `Insertion.insert`'s own
    /// drift guard treats an unrefreshed stale target as the existing manual-paste fallback, so
    /// there's no separate failure path to handle here. Pure aside from `refresh` itself, which
    /// production callers point at a live AX/`NSRunningApplication` lookup and tests point at a
    /// deterministic stub — see `AppLifecycleWindowPolicy`-style injectable defaults elsewhere in
    /// this file for the same testability pattern.
    nonisolated static func refreshedTarget(
        stale: InsertionTarget?,
        refresh: (InsertionTarget) -> InsertionTarget?
    ) -> InsertionTarget? {
        guard let stale else { return nil }
        return refresh(stale) ?? stale
    }

    /// Row-click insert from the Dictation History Quick Panel (PLAN.md F3.4). Unlike
    /// `insertLastDictation()` (which passes no target and therefore always attempts a synthetic
    /// paste), this passes the panel's snapshotted `target` through to `Insertion.insert`'s own
    /// drift guard — a stale or unverified target falls back to the same manual-paste HUD
    /// messaging (`insertLastDictationResultMessage`) as every other insertion path. Never an
    /// unverified paste. See PLAN.md F3.2.
    @discardableResult
    func insertFromHistoryPanel(_ text: String, target: InsertionTarget?) -> Bool {
        let outcome = Insertion.insert(text, target: target)
        if outcome.isPermissionClassFailure { refreshPermissionDiagnosis() }
        hud.flash(Self.insertLastDictationResultMessage(posted: outcome.posted))
        return outcome.posted
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
