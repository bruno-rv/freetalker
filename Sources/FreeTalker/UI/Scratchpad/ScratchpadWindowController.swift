import AppKit
import Combine

@MainActor
final class ScratchpadWindowController: NSWindowController, NSWindowDelegate, ScratchpadRecordingRouting, TranslationRecoveryPresentationRouting {
    static let shared = ScratchpadWindowController()

    let scratchpadDocument: ScratchpadDocument
    let scratchpadView: ScratchpadView

    private let startRecording: (RecordingDestination) -> Bool
    private let recordingIsBusy: () -> Bool
    private let stopRecording: () -> Void
    private let registerRouter: ((any ScratchpadRecordingRouting)?) -> Void
    private let registerTranslationRecoveryRouter: ((any TranslationRecoveryPresentationRouting)?) -> Void
    private let pendingRecordings: () -> [RecordingDestinationLifecycle.PendingRecording]
    private let consumePendingRecording: (ScratchpadInsertionToken) -> String?
    private let clearPendingRecording: (ScratchpadInsertionToken) -> Void
    private let consumePendingFailure: () -> String?
    private let translationRecoveryPresentation: () -> TranslationRecoveryPresentation?
    private let retryTranslation: () -> Void
    private let insertSourceText: () -> Void
    private let flush: (ScratchpadDocument) throws -> Void
    private let transformationService: any ScratchpadTransforming
    private let cloudLLMSnapshot: () -> CloudLLMSettingsSnapshot
    nonisolated private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    nonisolated(unsafe) private var textStorageObserver: NSObjectProtocol?
    private var cloudSettingsCancellable: AnyCancellable?
    nonisolated(unsafe) private var documentWarningCancellable: AnyCancellable?
    private var activeToken: ScratchpadInsertionToken?
    private var recoveries: [RecordingDestinationLifecycle.PendingRecording] = []
    private var retainedWarnings: [String] = []
    private var closeInProgress = false
    private var aiTask: Task<Void, Never>?
    private var aiGeneration: UInt64 = 0
    private var activeAIGeneration: UInt64?
    private var pendingAIAvailabilityRefresh = false

    convenience init() {
        let coordinator = AppCoordinator.shared
        self.init(
            documentURL: Self.defaultDocumentURL,
            startRecording: { coordinator.startHandsFreeRecording(destination: $0) },
            recordingIsBusy: { coordinator.isRecording || coordinator.isProcessing },
            stopRecording: { coordinator.stopCurrentRecording() },
            registerRouter: { coordinator.scratchpadRecordingRouter = $0 },
            registerTranslationRecoveryRouter: { coordinator.translationRecoveryPresentationRouter = $0 },
            pendingRecordings: { coordinator.pendingScratchpadRecordings() },
            consumePendingRecording: { coordinator.consumePendingScratchpadRecording(for: $0) },
            clearPendingRecording: { coordinator.clearPendingScratchpadRecording(for: $0) },
            consumePendingFailure: { coordinator.consumePendingScratchpadFailure() },
            translationRecoveryPresentation: { coordinator.nextTranslationRecoveryPresentation },
            retryTranslation: { coordinator.retryNextTranslation() },
            insertSourceText: { coordinator.insertNextTranslationSource() },
            flushDocument: { try $0.flush() },
            transformationService: ScratchpadTransformationService(),
            cloudLLMSnapshot: { AppSettings.shared.cloudLLMSnapshot }
        )
    }

    init(
        documentURL: URL,
        startRecording: @escaping (RecordingDestination) -> Bool,
        recordingIsBusy: @escaping () -> Bool,
        stopRecording: @escaping () -> Void,
        registerRouter: @escaping ((any ScratchpadRecordingRouting)?) -> Void,
        registerTranslationRecoveryRouter: @escaping ((any TranslationRecoveryPresentationRouting)?) -> Void = { _ in },
        pendingRecordings: @escaping () -> [RecordingDestinationLifecycle.PendingRecording],
        consumePendingRecording: @escaping (ScratchpadInsertionToken) -> String?,
        clearPendingRecording: @escaping (ScratchpadInsertionToken) -> Void,
        consumePendingFailure: @escaping () -> String?,
        translationRecoveryPresentation: @escaping () -> TranslationRecoveryPresentation? = { nil },
        retryTranslation: @escaping () -> Void = {},
        insertSourceText: @escaping () -> Void = {},
        flushDocument: @escaping (ScratchpadDocument) throws -> Void,
        saveDocument: ((NSAttributedString) throws -> Void)? = nil,
        transformationService: any ScratchpadTransforming = ScratchpadTransformationService(),
        cloudLLMSnapshot: @escaping () -> CloudLLMSettingsSnapshot = { AppSettings.shared.cloudLLMSnapshot },
        cloudConfigurationUpdates: AnyPublisher<Void, Never>? = nil,
        cloudCredentialUpdates: AnyPublisher<Void, Never>? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        scratchpadDocument = ScratchpadDocument(url: documentURL, save: saveDocument)
        scratchpadView = ScratchpadView(document: scratchpadDocument)
        self.startRecording = startRecording
        self.recordingIsBusy = recordingIsBusy
        self.stopRecording = stopRecording
        self.registerRouter = registerRouter
        self.registerTranslationRecoveryRouter = registerTranslationRecoveryRouter
        self.pendingRecordings = pendingRecordings
        self.consumePendingRecording = consumePendingRecording
        self.clearPendingRecording = clearPendingRecording
        self.consumePendingFailure = consumePendingFailure
        self.translationRecoveryPresentation = translationRecoveryPresentation
        self.retryTranslation = retryTranslation
        self.insertSourceText = insertSourceText
        self.flush = flushDocument
        self.transformationService = transformationService
        self.cloudLLMSnapshot = cloudLLMSnapshot
        self.notificationCenter = notificationCenter

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scratchpad"
        window.minSize = NSSize(width: 520, height: 360)
        window.contentView = scratchpadView
        window.isReleasedWhenClosed = false
        window.center()
        AppLifecycleWindowPolicy.configureFocusableUtilityWindow(window)
        super.init(window: window)
        window.delegate = self

        scratchpadView.onStartDictation = { [weak self] in self?.startDictation() }
        scratchpadView.onStopDictation = { [weak self] in self?.stopDictation() }
        scratchpadView.onInsertRecovery = { [weak self] in self?.insertRecovery() }
        scratchpadView.onRetryTranslation = { [weak self] in
            self?.retryTranslation()
        }
        scratchpadView.onInsertSourceText = { [weak self] in
            self?.insertSourceText()
        }
        scratchpadView.onAIAction = { [weak self] action in self?.performAIAction(action) }
        scratchpadView.onCustomAIAction = { [weak self] in self?.performCustomAIAction() }
        scratchpadView.onCustomInstructionChanged = { [weak self] in self?.refreshAIAvailability() }
        registerAsRouter()
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushDocument() }
        }
        textStorageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: scratchpadDocument.textStorage,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAIAvailability() }
        }
        let configurationUpdates = cloudConfigurationUpdates ?? Publishers.Merge3(
            AppSettings.shared.$llmProvider.map { _ in () },
            AppSettings.shared.$cloudLLMBaseURL.map { _ in () },
            AppSettings.shared.$cloudLLMModel.map { _ in () }
        ).dropFirst(3).eraseToAnyPublisher()
        let credentialUpdates = cloudCredentialUpdates ?? NotificationCenter.default.publisher(
            for: .cloudLLMCredentialsDidChange
        ).map { _ in () }.eraseToAnyPublisher()
        cloudSettingsCancellable = Publishers.Merge(configurationUpdates, credentialUpdates)
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refreshAIAvailability(markPendingWhileInFlight: true) }
        documentWarningCancellable = scratchpadDocument.$warning
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusPresentation() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        documentWarningCancellable?.cancel()
        if let terminationObserver { notificationCenter.removeObserver(terminationObserver) }
        if let textStorageObserver { NotificationCenter.default.removeObserver(textStorageObserver) }
    }

    func open(activate: Bool = true) {
        registerAsRouter()
        recoverPendingRecordings()
        if recoveries.isEmpty, let failure = consumePendingFailure() {
            retainWarning(failure)
        }
        updateStatusPresentation()
        refreshTranslationRecoveryPresentation()
        refreshAIAvailability()
        if activate { NSApplication.shared.activate(ignoringOtherApps: true) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(scratchpadView.textView)
    }

    func startDictation() {
        guard activeToken == nil, !scratchpadView.isRecording, !recordingIsBusy() else { return }
        let token = scratchpadView.editorController.makeTransformationToken()
        activeToken = token
        scratchpadView.previewText = nil
        scratchpadView.statusText = nil
        let destination = RecordingDestination.scratchpad(token)
        if startRecording(destination) {
            scratchpadView.isRecording = true
        } else if activeToken == token {
            activeToken = nil
            scratchpadView.isRecording = false
        }
    }

    func stopDictation() {
        guard activeToken != nil else { return }
        scratchpadView.isRecording = false
        scratchpadView.previewText = nil
        scratchpadView.statusText = "Processing…"
        stopRecording()
    }

    func updatePreview(_ text: String?, for token: ScratchpadInsertionToken) {
        guard token == activeToken else { return }
        scratchpadView.previewText = text
    }

    func completeRecording(_ text: String, for token: ScratchpadInsertionToken) -> Bool {
        guard token == activeToken else {
            enqueueRecovery(token: token, text: text)
            return false
        }
        scratchpadView.previewText = nil
        scratchpadView.statusText = nil
        scratchpadView.isRecording = false
        let accepted = scratchpadView.editorController.replaceTransformation(
            token,
            with: NSAttributedString(string: text),
            actionName: "Dictation"
        )
        activeToken = nil
        if accepted {
            clearPendingRecording(token)
        } else {
            enqueueRecovery(token: token, text: text)
        }
        return accepted
    }

    func completeTranslationRecovery(_ text: String, for token: ScratchpadInsertionToken) -> Bool {
        let accepted = scratchpadView.editorController.replaceTransformation(
            token,
            with: NSAttributedString(string: text),
            actionName: "Translation Recovery"
        )
        if accepted { clearPendingRecording(token) }
        else { scratchpadView.translationRecovery = translationRecoveryPresentation() }
        return accepted
    }

    func translationRecoveryPresentationDidChange() {
        refreshTranslationRecoveryPresentation()
    }

    func cancelRecording(for token: ScratchpadInsertionToken) {
        guard token == activeToken else { return }
        activeToken = nil
        scratchpadView.previewText = nil
        scratchpadView.statusText = nil
        scratchpadView.isRecording = false
        clearPendingRecording(token)
    }

    func failRecording(_ message: String, for token: ScratchpadInsertionToken) {
        guard token == activeToken else { return }
        activeToken = nil
        scratchpadView.previewText = nil
        scratchpadView.isRecording = false
        if closeInProgress { retainWarning(message) }
        else { scratchpadView.statusText = message }
    }

    func performCustomAIAction() {
        let instruction = scratchpadView.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            scratchpadView.aiErrorText = "Enter a custom instruction."
            return
        }
        performAIAction(.custom(instruction))
    }

    func performAIAction(_ action: ScratchpadAIAction) {
        guard aiTask == nil, let source = scratchpadView.editorController.captureTransformationSource() else {
            if aiTask == nil { scratchpadView.aiErrorText = "Enter text to transform." }
            return
        }
        let settings = cloudLLMSnapshot()
        let availability = ScratchpadAIAvailability.make(
            eligibility: settings.eligibility,
            hasInput: hasTransformationInput,
            isInFlight: false,
            hasInstruction: true,
            provider: settings.provider
        )
        guard availability.enabled else {
            scratchpadView.aiErrorText = availability.tooltip
            scratchpadView.updateAIAvailability(snapshot: settings, hasInput: hasTransformationInput)
            return
        }

        scratchpadView.aiErrorText = nil
        scratchpadView.isAIInFlight = true
        scratchpadView.updateAIAvailability(snapshot: settings, hasInput: true)
        aiGeneration &+= 1
        let generation = aiGeneration
        activeAIGeneration = generation
        aiTask = Task { [weak self, transformationService] in
            do {
                let result = try await transformationService.transform(source.originalText, action: action, snapshot: settings)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !result.isEmpty else { throw ScratchpadTransformationError.emptyResponse }
                guard let self, self.activeAIGeneration == generation else { return }
                if !self.scratchpadView.editorController.applyTransformation(result, to: source) {
                    self.scratchpadView.aiErrorText = "The source text changed. Nothing was replaced."
                }
            } catch let ScratchpadTransformationError.unavailable(eligibility) {
                if self?.activeAIGeneration == generation {
                    self?.scratchpadView.aiErrorText = CloudFeatureAvailability.make(
                        eligibility: eligibility, provider: settings.provider
                    ).tooltip
                }
            } catch is CancellationError {
                // Cancellation leaves the source untouched and needs no destructive alert.
            } catch {
                if self?.activeAIGeneration == generation {
                    self?.scratchpadView.aiErrorText = "The transformation failed. Try again."
                }
            }
            guard let self, self.activeAIGeneration == generation else { return }
            self.activeAIGeneration = nil
            self.aiTask = nil
            self.scratchpadView.isAIInFlight = false
            if self.pendingAIAvailabilityRefresh {
                self.refreshAIAvailability()
            } else {
                self.scratchpadView.updateAIAvailability(snapshot: settings, hasInput: self.hasTransformationInput)
            }
        }
    }

    private func refreshAIAvailability(markPendingWhileInFlight: Bool = false) {
        guard !scratchpadView.isAIInFlight else {
            if markPendingWhileInFlight { pendingAIAvailabilityRefresh = true }
            return
        }
        pendingAIAvailabilityRefresh = false
        let settings = cloudLLMSnapshot()
        scratchpadView.updateAIAvailability(
            snapshot: settings,
            hasInput: hasTransformationInput
        )
    }

    private var hasTransformationInput: Bool {
        !scratchpadDocument.textStorage.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func windowWillClose(_ notification: Notification) {
        aiGeneration &+= 1
        activeAIGeneration = nil
        pendingAIAvailabilityRefresh = false
        aiTask?.cancel()
        aiTask = nil
        scratchpadView.isAIInFlight = false
        closeInProgress = true
        scratchpadView.statusText = nil
        if activeToken != nil, scratchpadView.isRecording { stopRecording() }
        flushDocument()
        registerRouter(nil)
        registerTranslationRecoveryRouter(nil)
        activeToken = nil
        scratchpadView.isRecording = false
        scratchpadView.previewText = nil
        closeInProgress = false
    }

    private func registerAsRouter() {
        registerRouter(self)
        registerTranslationRecoveryRouter(self)
    }

    private func recoverPendingRecordings() {
        for item in pendingRecordings() { enqueueRecovery(token: item.token, text: item.text) }
        renderCurrentRecovery()
    }

    private func enqueueRecovery(token: ScratchpadInsertionToken, text: String) {
        guard !recoveries.contains(where: { $0.token == token }) else { return }
        recoveries.append(.init(token: token, text: text))
        renderCurrentRecovery()
    }

    private func renderCurrentRecovery() {
        scratchpadView.recoveryText = recoveries.first?.text
        updateStatusPresentation()
    }

    private func refreshTranslationRecoveryPresentation() {
        scratchpadView.translationRecovery = translationRecoveryPresentation()
    }

    private func insertRecovery() {
        guard let recovery = recoveries.first else { return }
        let token = scratchpadView.editorController.makeTransformationToken()
        guard scratchpadView.editorController.replaceTransformation(
            token,
            with: NSAttributedString(string: recovery.text),
            actionName: "Recover Dictation"
        ) else { return }
        _ = consumePendingRecording(recovery.token)
        recoveries.removeFirst()
        renderCurrentRecovery()
    }

    private func flushDocument() {
        do { try flush(scratchpadDocument) }
        catch {
            retainWarning("The scratchpad could not be saved.")
            updateStatusPresentation()
        }
    }

    private func retainWarning(_ message: String) {
        retainedWarnings.append(message)
    }

    private func updateStatusPresentation() {
        var messages = retainedWarnings
        if let warning = scratchpadDocument.warning, !messages.contains(warning) {
            messages.append(warning)
        }
        if !recoveries.isEmpty {
            messages.append("The original insertion point changed. The transcription is preserved below.")
        }
        scratchpadView.statusText = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private static var defaultDocumentURL: URL {
        let support = FreeTalkerPaths.applicationSupport
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("scratchpad.rtf")
    }
}
