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
        var pending: [ScratchpadInsertionToken: String] = [:]
        let harness = Harness(
            "Text",
            pending: { pending[$0] },
            consumePending: { pending.removeValue(forKey: $0) }
        )
        harness.controller.startDictation()
        let token = harness.startedToken
        harness.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        pending[token] = "completed while closed"

        harness.controller.open(activate: false)

        #expect(harness.controller.scratchpadView.recoveryText == "completed while closed")
        #expect(pending[token] == nil)
        #expect(harness.registeredRouter === harness.controller)
    }

    @Test func startUsesScratchpadDestinationAndStopUsesCoordinatorCallback() {
        let harness = Harness("Text")
        harness.controller.startDictation()
        #expect(harness.startedDestinations == [.scratchpad(harness.startedToken)])
        #expect(harness.controller.scratchpadView.isRecording)

        harness.controller.stopDictation()
        #expect(harness.stopCalls == 1)
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

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("rtf")
    }

    private func makeController(
        url: URL,
        notificationCenter: NotificationCenter = .default
    ) -> ScratchpadWindowController {
        ScratchpadWindowController(
            documentURL: url,
            startRecording: { _ in true },
            stopRecording: {},
            registerRouter: { _ in },
            pendingRecording: { _ in nil },
            consumePendingRecording: { _ in nil },
            clearPendingRecording: { _ in },
            notificationCenter: notificationCenter
        )
    }
}

@MainActor
private final class Harness {
    private let probe: CallbackProbe
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
        pending: @escaping (ScratchpadInsertionToken) -> String? = { _ in nil },
        consumePending: @escaping (ScratchpadInsertionToken) -> String? = { _ in nil }
    ) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("rtf")
        let probe = CallbackProbe()
        self.probe = probe
        controller = ScratchpadWindowController(
            documentURL: url,
            startRecording: { destination in probe.startedDestinations.append(destination); return true },
            stopRecording: { probe.stopCalls += 1 },
            registerRouter: { probe.registeredRouter = $0 },
            pendingRecording: pending,
            consumePendingRecording: consumePending,
            clearPendingRecording: { _ in }
        )
        controller.scratchpadDocument.textStorage.append(NSAttributedString(string: text))
    }
}

@MainActor
private final class CallbackProbe {
    var startedDestinations: [RecordingDestination] = []
    var stopCalls = 0
    weak var registeredRouter: (any ScratchpadRecordingRouting)?
}
