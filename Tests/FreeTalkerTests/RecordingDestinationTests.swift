import Foundation
import Testing
@testable import FreeTalker

@Suite("Recording destinations")
struct RecordingDestinationTests {
    @Test func scratchpadDestinationKeepsItsInsertionToken() {
        let token = ScratchpadInsertionToken(id: UUID())

        #expect(RecordingDestination.scratchpad(token) == .scratchpad(token))
        #expect(RecordingDestination.external != .scratchpad(token))
    }

    @Test func launcherStartDoesNotToggleAnActiveRecording() {
        #expect(AppCoordinator.launcherStartDecision(isRecording: false, isProcessing: false))
        #expect(!AppCoordinator.launcherStartDecision(isRecording: true, isProcessing: false))
        #expect(!AppCoordinator.launcherStartDecision(isRecording: false, isProcessing: true))
    }

    @Test func startFailureAndTerminalPathsResetDestinationState() {
        let destination = RecordingDestination.scratchpad(.init(id: UUID()))
        #expect(AppCoordinator.destinationAfterCaptureStart(started: false, destination: destination) == nil)
        #expect(AppCoordinator.destinationAfterCaptureStart(started: true, destination: destination) == destination)

        var stored: RecordingDestination? = destination
        #expect(AppCoordinator.takeTerminalDestination(&stored) == destination)
        #expect(stored == nil)
    }

    @MainActor
    @Test func coordinatorDoesNotRetainScratchpadRouter() {
        weak var releasedRouter: RouterProbe?
        do {
            let router = RouterProbe()
            releasedRouter = router
            AppCoordinator.shared.scratchpadRecordingRouter = router
        }

        #expect(releasedRouter == nil)
        #expect(AppCoordinator.shared.scratchpadRecordingRouter == nil)
    }

    @MainActor
    @Test func externalCompletionRunsOnlyExternalSideEffects() throws {
        var externalCalls = 0
        let router = RouterProbe()

        let accepted = try AppCoordinator.routeDestinationEvent(
            .completion("external text"), destination: .external, router: router
        ) { externalCalls += 1 }

        #expect(accepted)
        #expect(externalCalls == 1)
        #expect(router.events.isEmpty)
    }

    @MainActor
    @Test func scratchpadEventsRunOnlyRouterSideEffects() throws {
        let token = ScratchpadInsertionToken(id: UUID())
        let router = RouterProbe()
        var externalCalls = 0

        _ = try AppCoordinator.routeDestinationEvent(.preview("draft"), destination: .scratchpad(token), router: router) { externalCalls += 1 }
        let accepted = try AppCoordinator.routeDestinationEvent(.completion("final"), destination: .scratchpad(token), router: router) { externalCalls += 1 }
        _ = try AppCoordinator.routeDestinationEvent(.cancellation, destination: .scratchpad(token), router: router) { externalCalls += 1 }
        _ = try AppCoordinator.routeDestinationEvent(.failure("failed"), destination: .scratchpad(token), router: router) { externalCalls += 1 }

        #expect(accepted)
        #expect(externalCalls == 0)
        #expect(router.events == [.preview("draft"), .completion("final"), .cancellation, .failure("failed")])
    }

    @MainActor
    @Test func rejectedScratchpadCompletionIsNotAccepted() throws {
        let router = RouterProbe(acceptCompletion: false)
        let accepted = try AppCoordinator.routeDestinationEvent(
            .completion("recoverable"),
            destination: .scratchpad(.init(id: UUID())),
            router: router
        ) {}
        #expect(!accepted)
    }
}

@MainActor
private final class RouterProbe: ScratchpadRecordingRouting {
    var events: [RecordingDestinationEvent] = []
    let acceptCompletion: Bool

    init(acceptCompletion: Bool = true) { self.acceptCompletion = acceptCompletion }
    func updatePreview(_ text: String?, for token: ScratchpadInsertionToken) { events.append(.preview(text)) }
    func completeRecording(_ text: String, for token: ScratchpadInsertionToken) -> Bool {
        events.append(.completion(text))
        return acceptCompletion
    }
    func cancelRecording(for token: ScratchpadInsertionToken) { events.append(.cancellation) }
    func failRecording(_ message: String, for token: ScratchpadInsertionToken) { events.append(.failure(message)) }
}
