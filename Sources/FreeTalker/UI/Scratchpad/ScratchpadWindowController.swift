import AppKit

@MainActor
final class ScratchpadWindowController: NSWindowController, NSWindowDelegate, ScratchpadRecordingRouting {
    static let shared = ScratchpadWindowController()

    let scratchpadDocument: ScratchpadDocument
    let scratchpadView: ScratchpadView

    private let startRecording: (RecordingDestination) -> Bool
    private let stopRecording: () -> Void
    private let registerRouter: ((any ScratchpadRecordingRouting)?) -> Void
    private let pendingRecording: (ScratchpadInsertionToken) -> String?
    private let consumePendingRecording: (ScratchpadInsertionToken) -> String?
    private let clearPendingRecording: (ScratchpadInsertionToken) -> Void
    nonisolated private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?
    private var activeToken: ScratchpadInsertionToken?

    convenience init() {
        let coordinator = AppCoordinator.shared
        self.init(
            documentURL: Self.defaultDocumentURL,
            startRecording: { coordinator.startHandsFreeRecording(destination: $0) },
            stopRecording: { coordinator.stopCurrentRecording() },
            registerRouter: { coordinator.scratchpadRecordingRouter = $0 },
            pendingRecording: { coordinator.pendingScratchpadRecording(for: $0) },
            consumePendingRecording: { coordinator.consumePendingScratchpadRecording(for: $0) },
            clearPendingRecording: { coordinator.clearPendingScratchpadRecording(for: $0) }
        )
    }

    init(
        documentURL: URL,
        startRecording: @escaping (RecordingDestination) -> Bool,
        stopRecording: @escaping () -> Void,
        registerRouter: @escaping ((any ScratchpadRecordingRouting)?) -> Void,
        pendingRecording: @escaping (ScratchpadInsertionToken) -> String?,
        consumePendingRecording: @escaping (ScratchpadInsertionToken) -> String?,
        clearPendingRecording: @escaping (ScratchpadInsertionToken) -> Void,
        notificationCenter: NotificationCenter = .default
    ) {
        scratchpadDocument = ScratchpadDocument(url: documentURL)
        scratchpadView = ScratchpadView(document: scratchpadDocument)
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.registerRouter = registerRouter
        self.pendingRecording = pendingRecording
        self.consumePendingRecording = consumePendingRecording
        self.clearPendingRecording = clearPendingRecording
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
        recoverPendingRecording()
        if activate { NSApplication.shared.activate(ignoringOtherApps: true) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(scratchpadView.textView)
    }

    func startDictation() {
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
            preserveForRecovery(text)
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
            preserveForRecovery(text)
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
        flushDocument()
        registerRouter(nil)
    }

    private func registerAsRouter() {
        registerRouter(self)
    }

    private func recoverPendingRecording() {
        guard let token = activeToken, pendingRecording(token) != nil,
              let text = consumePendingRecording(token) else { return }
        preserveForRecovery(text)
        activeToken = nil
        scratchpadView.isRecording = false
    }

    private func preserveForRecovery(_ text: String) {
        scratchpadView.recoveryText = text
        scratchpadView.statusText = "The original insertion point changed. The transcription is preserved below."
    }

    private func insertRecovery() {
        guard let text = scratchpadView.recoveryText else { return }
        let token = scratchpadView.editorController.makeTransformationToken()
        guard scratchpadView.editorController.replaceTransformation(
            token,
            with: NSAttributedString(string: text),
            actionName: "Recover Dictation"
        ) else { return }
        scratchpadView.recoveryText = nil
        scratchpadView.statusText = nil
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
