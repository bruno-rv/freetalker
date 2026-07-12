import AppKit
import Foundation
import Testing
@testable import FreeTalker

@Suite("Scratchpad recording", .serialized)
@MainActor
struct ScratchpadRecordingTests {
    @Test func completionInsertsAtCapturedInsertionPointAndUsesTextViewUndo() {
        let harness = Harness("Hello world")
        harness.controller.scratchpadView.textView.setSelectedRange(NSRange(location: 5, length: 0))

        harness.controller.startDictation()
        let token = harness.startedToken
        #expect(harness.controller.completeRecording(" brave", for: token))
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Hello brave world")

        harness.controller.scratchpadView.textView.undoManager?.undo()
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Hello world")
    }

    @Test func completionReplacesCapturedSelection() {
        let harness = Harness("Hello world")
        harness.controller.scratchpadView.textView.setSelectedRange(NSRange(location: 6, length: 5))

        harness.controller.startDictation()
        #expect(harness.controller.completeRecording("there", for: harness.startedToken))
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Hello there")
    }

    @Test func previewNeverEntersStorageOrUndoHistory() {
        let harness = Harness("Stored")
        harness.controller.startDictation()
        let token = harness.startedToken

        harness.controller.updatePreview("temporary words", for: token)

        #expect(harness.controller.scratchpadDocument.textStorage.string == "Stored")
        #expect(harness.controller.scratchpadView.previewText == "temporary words")
        #expect(harness.controller.scratchpadView.textView.undoManager?.canUndo == false)
    }

    @Test func cancellationAndFailureLeaveDocumentUnchanged() {
        let harness = Harness("Keep me")
        harness.controller.startDictation()
        let token = harness.startedToken
        harness.controller.updatePreview("temporary", for: token)
        harness.controller.cancelRecording(for: token)
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Keep me")
        #expect(harness.controller.scratchpadView.previewText == nil)

        harness.controller.startDictation()
        let secondToken = harness.startedToken
        harness.controller.failRecording("Microphone unavailable", for: secondToken)
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Keep me")
        #expect(harness.controller.scratchpadView.statusText == "Microphone unavailable")
    }

    @Test func invalidatedTokenPreservesTranscriptionForExplicitRecovery() {
        let harness = Harness("Original")
        harness.controller.startDictation()
        let token = harness.startedToken
        harness.controller.scratchpadDocument.textStorage.append(NSAttributedString(string: " changed"))

        #expect(!harness.controller.completeRecording("recover this", for: token))
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Original changed")
        #expect(harness.controller.scratchpadView.recoveryText == "recover this")
    }

    @Test func reopeningRegistersRouterAndConsumesPendingTextIntoVisibleRecovery() {
        let harness = Harness("Text")
        harness.controller.startDictation()
        let token = harness.startedToken
        harness.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        harness.probe.storePending("completed while closed", token: token)

        harness.controller.open(activate: false)

        #expect(harness.controller.scratchpadView.recoveryText == "completed while closed")
        #expect(harness.probe.pending[token] == "completed while closed")
        #expect(harness.registeredRouter === harness.controller)
    }

    @Test func twoRecoveriesRemainFIFOAndConsumeOnlyAfterSuccessfulInsertion() {
        let harness = Harness("Base")
        let first = ScratchpadInsertionToken(id: UUID())
        let second = ScratchpadInsertionToken(id: UUID())
        harness.probe.storePending(" one", token: first)
        harness.probe.storePending(" two", token: second)
        harness.controller.open(activate: false)
        #expect(harness.controller.scratchpadView.recoveryText == " one")

        harness.controller.scratchpadView.textView.setSelectedRange(NSRange(location: 4, length: 0))
        harness.controller.scratchpadView.recoveryButton.performClick(nil)
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Base one")
        #expect(harness.probe.pending[first] == nil)
        #expect(harness.probe.pending[second] == " two")
        #expect(harness.controller.scratchpadView.recoveryText == " two")

        harness.controller.scratchpadView.textView.setSelectedRange(NSRange(location: 8, length: 0))
        harness.controller.scratchpadView.recoveryButton.performClick(nil)
        #expect(harness.controller.scratchpadDocument.textStorage.string == "Base one two")
        #expect(harness.probe.pending.isEmpty)
        #expect(harness.controller.scratchpadView.recoveryText == nil)
    }

    @Test func closeDuringCaptureStopsThenCompletionBecomesPendingAndReopensIdle() throws {
        let harness = Harness("Base")
        harness.controller.startDictation()
        let token = harness.startedToken

        harness.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(harness.stopCalls == 1)
        #expect(harness.registeredRouter == nil)
        #expect(!harness.controller.scratchpadView.isRecording)
        #expect(harness.controller.scratchpadView.previewText == nil)

        _ = try harness.probe.lifecycle.complete(" closed", destination: .scratchpad(token)) {}
        harness.controller.open(activate: false)
        #expect(!harness.controller.scratchpadView.isRecording)
        #expect(harness.controller.scratchpadView.statusText != "Processing…")
        #expect(harness.controller.scratchpadView.recoveryText == " closed")
    }

    @Test func cancellationAndFailureWhileClosedReopenIdleWithoutStaleProcessing() async {
        let cancelled = Harness("Base")
        cancelled.controller.startDictation()
        let cancelledToken = cancelled.startedToken
        cancelled.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        cancelled.probe.lifecycle.install(.scratchpad(cancelledToken))
        cancelled.probe.lifecycle.cancel(stop: {})
        cancelled.controller.open(activate: false)
        #expect(!cancelled.controller.scratchpadView.isRecording)
        #expect(cancelled.controller.scratchpadView.statusText == nil)

        let failed = Harness("Base")
        failed.controller.startDictation()
        let failedToken = failed.startedToken
        failed.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        do {
            _ = try await failed.probe.lifecycle.runAsync(
                destination: .scratchpad(failedToken), process: { throw ClosedFailure() },
                text: { $0 as String }, external: { _ in }
            )
        } catch {}
        failed.controller.open(activate: false)
        #expect(!failed.controller.scratchpadView.isRecording)
        #expect(failed.controller.scratchpadView.statusText == "closed failure")
    }

    @Test func repeatedStartPreservesOriginalRecordingToken() {
        let harness = Harness("Base")
        harness.controller.startDictation()
        let original = harness.startedToken
        harness.controller.startDictation()
        #expect(harness.startedDestinations == [.scratchpad(original)])
    }

    @Test func busyCoordinatorRejectsStartBeforeCreatingADestination() {
        let harness = Harness("Base")
        harness.probe.isBusy = true
        harness.controller.startDictation()
        #expect(harness.startedDestinations.isEmpty)
        #expect(!harness.controller.scratchpadView.isRecording)
    }

    @Test func startUsesScratchpadDestinationAndStopUsesCoordinatorCallback() {
        let harness = Harness("Text")
        harness.controller.startDictation()
        #expect(harness.startedDestinations == [.scratchpad(harness.startedToken)])
        #expect(harness.controller.scratchpadView.isRecording)

        harness.controller.stopDictation()
        #expect(harness.stopCalls == 1)
    }

    @Test func windowControllerAndAppCoordinatorLifecycleCompleteThenRecoverWithoutCapture() {
        let coordinator = AppCoordinator.shared
        var recoveryTokenToClear: ScratchpadInsertionToken?
        defer {
            if let recoveryTokenToClear { coordinator.clearPendingScratchpadRecording(for: recoveryTokenToClear) }
            coordinator.scratchpadRecordingRouter = nil
        }
        var destination: RecordingDestination?
        let wired = ScratchpadWindowController(
            documentURL: temporaryURL(),
            startRecording: { destination = $0; return true },
            recordingIsBusy: { false },
            stopRecording: {},
            registerRouter: { coordinator.scratchpadRecordingRouter = $0 },
            pendingRecordings: { coordinator.pendingScratchpadRecordings() },
            consumePendingRecording: { coordinator.consumePendingScratchpadRecording(for: $0) },
            clearPendingRecording: { coordinator.clearPendingScratchpadRecording(for: $0) },
            consumePendingFailure: { coordinator.consumePendingScratchpadFailure() },
            flushDocument: { try $0.flush() }
        )
        wired.scratchpadDocument.textStorage.append(NSAttributedString(string: "Base"))
        wired.scratchpadView.textView.setSelectedRange(NSRange(location: 4, length: 0))
        wired.startDictation()
        guard case .scratchpad(let token) = destination else {
            Issue.record("Expected a scratchpad destination")
            return
        }
        #expect(coordinator.deliverScratchpadCompletion(" one", for: token))
        #expect(wired.scratchpadDocument.textStorage.string == "Base one")

        wired.startDictation()
        guard case .scratchpad(let recoveryToken) = destination else { return }
        recoveryTokenToClear = recoveryToken
        wired.scratchpadDocument.textStorage.append(NSAttributedString(string: " changed"))
        #expect(!coordinator.deliverScratchpadCompletion(" recover", for: recoveryToken))
        #expect(wired.scratchpadView.recoveryText == " recover")
        #expect(coordinator.pendingScratchpadRecording(for: recoveryToken) == " recover")
    }

    @Test func windowIsNormalFocusableAndFormattingToolbarIsAccessible() {
        let harness = Harness("Text")
        let window = harness.controller.window
        #expect(window?.styleMask.contains([.titled, .closable, .resizable]) == true)
        #expect(window?.canBecomeKey == true)
        #expect(harness.controller.scratchpadView.formattingButtons.count == 7)
        #expect(harness.controller.scratchpadView.formattingButtons.allSatisfy {
            ($0.accessibilityLabel()?.isEmpty == false) && ($0.toolTip?.isEmpty == false)
        })
        let dictate = harness.controller.scratchpadView.formattingButtons.last
        #expect(dictate?.accessibilityLabel() == "Start scratchpad dictation")
        #expect(dictate?.accessibilityHelp() == "Record speech at the current scratchpad selection")
        harness.controller.startDictation()
        #expect(dictate?.accessibilityLabel() == "Stop scratchpad dictation")
        #expect(dictate?.accessibilityHelp() == "Stop recording and transcribe into the scratchpad")
        #expect(harness.controller.scratchpadView.recoveryButton.accessibilityHelp()?.isEmpty == false)
    }

    @Test func windowJoinsOtherApplicationsFullScreenSpacesWithoutBecomingAHUD() throws {
        let window = try #require(Harness("Text").controller.window)

        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.canJoinAllApplications))
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!window.collectionBehavior.contains(.stationary))
        #expect(window.level == .normal)
        #expect(window.level != .floating)
        #expect(window.styleMask.contains([.titled, .closable, .resizable]))
        #expect(!window.styleMask.contains(.nonactivatingPanel))
        #expect(window.canBecomeKey)
    }

    @Test func closeAndTerminationFlushDocument() {
        let closeURL = temporaryURL()
        let closeController = makeController(url: closeURL)
        closeController.scratchpadDocument.textStorage.append(NSAttributedString(string: "close save"))
        closeController.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(ScratchpadPersistence(url: closeURL).load().text.string == "close save")

        let center = NotificationCenter()
        let terminationURL = temporaryURL()
        let terminationController = makeController(url: terminationURL, notificationCenter: center)
        terminationController.scratchpadDocument.textStorage.append(NSAttributedString(string: "termination save"))
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(ScratchpadPersistence(url: terminationURL).load().text.string == "termination save")
        _ = terminationController
    }

    @Test func closeFlushFailureSurvivesReopenWithInMemoryDocument() {
        let controller = makeController(
            url: temporaryURL(),
            flushDocument: { _ in throw CloseFailure.save }
        )
        controller.scratchpadDocument.textStorage.append(NSAttributedString(string: "unsaved"))

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.open(activate: false)

        #expect(controller.scratchpadDocument.textStorage.string == "unsaved")
        #expect(controller.scratchpadView.statusText?.contains("could not be saved") == true)
    }

    @Test func corruptDocumentWarningIsVisibleOnFirstOpenWithoutOverwritingSource() throws {
        let url = temporaryURL()
        let corrupt = Data("not rtf".utf8)
        try corrupt.write(to: url)
        let controller = makeController(url: url)

        controller.open(activate: false)

        #expect(controller.scratchpadView.statusText == "The scratchpad could not be opened. Its original file has been preserved.")
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func debouncedSaveFailureAppearsWhileOpenAndSuccessfulRetryClearsIt() async throws {
        var saveAttempts = 0
        let url = temporaryURL()
        let controller = makeController(url: url, saveDocument: { text in
            saveAttempts += 1
            if saveAttempts == 1 { throw CloseFailure.save }
            try ScratchpadPersistence(url: url).save(text)
        })
        controller.open(activate: false)

        controller.scratchpadDocument.textStorage.append(NSAttributedString(string: "retry me"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.scratchpadView.statusText == "The scratchpad could not be saved.")

        controller.scratchpadDocument.scheduleSave()
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.scratchpadView.statusText == nil)
        #expect(ScratchpadPersistence(url: url).load().text.string == "retry me")
    }

    @Test func synchronousStopFailureAndSaveFailureBothSurviveCloseInOrder() {
        let harness = Harness("Base", flushDocument: { _ in throw CloseFailure.save })
        harness.controller.startDictation()
        let token = harness.startedToken
        harness.probe.onStop = { [weak controller = harness.controller] in
            controller?.failRecording("stop failed", for: token)
        }

        harness.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        harness.controller.open(activate: false)

        #expect(!harness.controller.scratchpadView.isRecording)
        #expect(harness.controller.scratchpadView.previewText == nil)
        #expect(harness.controller.scratchpadView.statusText == "stop failed\nThe scratchpad could not be saved.")
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("rtf")
    }

    private func makeController(
        url: URL,
        notificationCenter: NotificationCenter = .default,
        flushDocument: @escaping (ScratchpadDocument) throws -> Void = { try $0.flush() },
        saveDocument: ((NSAttributedString) throws -> Void)? = nil
    ) -> ScratchpadWindowController {
        ScratchpadWindowController(
            documentURL: url,
            startRecording: { _ in true },
            recordingIsBusy: { false },
            stopRecording: {},
            registerRouter: { _ in },
            pendingRecordings: { [] },
            consumePendingRecording: { _ in nil },
            clearPendingRecording: { _ in },
            consumePendingFailure: { nil },
            flushDocument: flushDocument,
            saveDocument: saveDocument,
            notificationCenter: notificationCenter
        )
    }
}

@MainActor
private final class Harness {
    let probe: CallbackProbe
    let controller: ScratchpadWindowController

    var startedDestinations: [RecordingDestination] { probe.startedDestinations }
    var stopCalls: Int { probe.stopCalls }
    var registeredRouter: (any ScratchpadRecordingRouting)? { probe.registeredRouter }

    var startedToken: ScratchpadInsertionToken {
        guard case .scratchpad(let token) = startedDestinations.last else {
            Issue.record("Expected a scratchpad recording destination")
            return ScratchpadInsertionToken(id: UUID())
        }
        return token
    }

    init(
        _ text: String,
        flushDocument: @escaping (ScratchpadDocument) throws -> Void = { try $0.flush() }
    ) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("rtf")
        let probe = CallbackProbe()
        self.probe = probe
        controller = ScratchpadWindowController(
            documentURL: url,
            startRecording: { destination in
                probe.startedDestinations.append(destination)
                probe.lifecycle.install(destination)
                return true
            },
            recordingIsBusy: { probe.isBusy },
            stopRecording: { probe.stopCalls += 1; probe.onStop() },
            registerRouter: { probe.registeredRouter = $0; probe.lifecycle.router = $0 },
            pendingRecordings: { probe.lifecycle.pendingRecordings() },
            consumePendingRecording: { probe.lifecycle.consumePending(for: $0) },
            clearPendingRecording: { probe.lifecycle.clearPending(for: $0) },
            consumePendingFailure: { probe.lifecycle.consumePendingFailure() },
            flushDocument: flushDocument
        )
        controller.scratchpadDocument.textStorage.append(NSAttributedString(string: text))
    }
}

@MainActor
private final class CallbackProbe {
    let lifecycle = RecordingDestinationLifecycle()
    var startedDestinations: [RecordingDestination] = []
    var stopCalls = 0
    var isBusy = false
    var onStop: () -> Void = {}
    weak var registeredRouter: (any ScratchpadRecordingRouting)?
    var pending: [ScratchpadInsertionToken: String] {
        Dictionary(uniqueKeysWithValues: lifecycle.pendingRecordings().map { ($0.token, $0.text) })
    }
    func storePending(_ text: String, token: ScratchpadInsertionToken) {
        lifecycle.storePending(text, for: token)
    }
}

private struct ClosedFailure: Error, LocalizedError {
    var errorDescription: String? { "closed failure" }
}

private enum CloseFailure: Error {
    case save
}
