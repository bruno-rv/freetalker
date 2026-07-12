import AppKit

@MainActor
final class ScratchpadWindowController: NSWindowController, NSWindowDelegate, ScratchpadRecordingRouting {
    static let shared = ScratchpadWindowController()

    let scratchpadDocument: ScratchpadDocument
    let scratchpadView: ScratchpadView

    private let startRecording: (RecordingDestination) -> Bool
    private let recordingIsBusy: () -> Bool
    private let stopRecording: () -> Void
    private let registerRouter: ((any ScratchpadRecordingRouting)?) -> Void
    private let pendingRecordings: () -> [RecordingDestinationLifecycle.PendingRecording]
    private let consumePendingRecording: (ScratchpadInsertionToken) -> String?
    private let clearPendingRecording: (ScratchpadInsertionToken) -> Void
    private let consumePendingFailure: () -> String?
    nonisolated private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    private var activeToken: ScratchpadInsertionToken?
    private var recoveries: [RecordingDestinationLifecycle.PendingRecording] = []

    convenience init() {
        let coordinator = AppCoordinator.shared
        self.init(
            documentURL: Self.defaultDocumentURL,
            startRecording: { coordinator.startHandsFreeRecording(destination: $0) },
            recordingIsBusy: { coordinator.isRecording || coordinator.isProcessing },
            stopRecording: { coordinator.stopCurrentRecording() },
            registerRouter: { coordinator.scratchpadRecordingRouter = $0 },
            pendingRecordings: { coordinator.pendingScratchpadRecordings() },
            consumePendingRecording: { coordinator.consumePendingScratchpadRecording(for: $0) },
            clearPendingRecording: { coordinator.clearPendingScratchpadRecording(for: $0) },
            consumePendingFailure: { coordinator.consumePendingScratchpadFailure() }
        )
    }

    init(
        documentURL: URL,
        startRecording: @escaping (RecordingDestination) -> Bool,
        recordingIsBusy: @escaping () -> Bool,
        stopRecording: @escaping () -> Void,
        registerRouter: @escaping ((any ScratchpadRecordingRouting)?) -> Void,
        pendingRecordings: @escaping () -> [RecordingDestinationLifecycle.PendingRecording],
        consumePendingRecording: @escaping (ScratchpadInsertionToken) -> String?,
        clearPendingRecording: @escaping (ScratchpadInsertionToken) -> Void,
        consumePendingFailure: @escaping () -> String?,
        notificationCenter: NotificationCenter = .default
    ) {
        scratchpadDocument = ScratchpadDocument(url: documentURL)
        scratchpadView = ScratchpadView(document: scratchpadDocument)
        self.startRecording = startRecording
        self.recordingIsBusy = recordingIsBusy
        self.stopRecording = stopRecording
        self.registerRouter = registerRouter
        self.pendingRecordings = pendingRecordings
        self.consumePendingRecording = consumePendingRecording
        self.clearPendingRecording = clearPendingRecording
        self.consumePendingFailure = consumePendingFailure
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
        super.init(window: window)
        window.delegate = self

        scratchpadView.onStartDictation = { [weak self] in self?.startDictation() }
        scratchpadView.onStopDictation = { [weak self] in self?.stopDictation() }
        scratchpadView.onInsertRecovery = { [weak self] in self?.insertRecovery() }
        registerAsRouter()
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushDocument() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let terminationObserver { notificationCenter.removeObserver(terminationObserver) }
    }

    func open(activate: Bool = true) {
        registerAsRouter()
        recoverPendingRecordings()
        if recoveries.isEmpty, let failure = consumePendingFailure() {
            scratchpadView.statusText = failure
        }
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
        scratchpadView.statusText = message
        scratchpadView.isRecording = false
    }

    func windowWillClose(_ notification: Notification) {
        if activeToken != nil, scratchpadView.isRecording { stopRecording() }
        flushDocument()
        registerRouter(nil)
        activeToken = nil
        scratchpadView.isRecording = false
        scratchpadView.previewText = nil
        scratchpadView.statusText = nil
    }

    private func registerAsRouter() {
        registerRouter(self)
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
        if recoveries.isEmpty {
            if scratchpadView.statusText == "The original insertion point changed. The transcription is preserved below." {
                scratchpadView.statusText = nil
            }
        } else {
            scratchpadView.statusText = "The original insertion point changed. The transcription is preserved below."
        }
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
        do { try scratchpadDocument.flush() }
        catch { scratchpadView.statusText = "The scratchpad could not be saved." }
    }

    private static var defaultDocumentURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FreeTalker", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("scratchpad.rtf")
    }
}
